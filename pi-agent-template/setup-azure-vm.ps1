# =============================================================================
# Azure VM Provisioning Script - Pi Coding Agent
# Run once to create the VM infrastructure.
#
# Prerequisites:
#   - Azure CLI installed: https://aka.ms/installazurecliwindows
#   - Bicep CLI: az bicep install
#   - Logged in: az login
# =============================================================================

param(
    [string]$ResourceGroup     = "",
    [string]$VmName            = "",
    [string]$Location          = "",
    [string]$VmSize            = "",
    [string]$AdminUser         = "",
    [string]$SshKeyPath        = "",
    [int]   $DiskSizeGb        = 0,
    [string]$AutoShutdownTime  = "",
    [int]   $CpuThresholdPct   = 0,
    [int]   $IdleMinutes       = 0,
    [string]$TagOwner          = "",
    [string]$TagEnvironment    = "",
    [string]$TagProject        = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$bicepFile = "$PSScriptRoot\bicep\main.bicep"

# --- Load personal config defaults -------------------------------------------

$configFile = "$PSScriptRoot\setup-azure-vm.config.ps1"
if (-not (Test-Path $configFile)) {
    Write-Error "Config file not found: $configFile`nCopy setup-azure-vm.config.example.ps1 to setup-azure-vm.config.ps1 and fill in your values."
    Read-Host "Press Enter to close"
    exit 1
}
$cfg = & $configFile
foreach ($key in $cfg.Keys) {
    $bound = $PSBoundParameters.ContainsKey($key)
    $cur   = Get-Variable -Name $key -ValueOnly -ErrorAction SilentlyContinue
    if (-not $bound -and (-not $cur -or ($cur -is [int] -and $cur -eq 0))) {
        Set-Variable -Name $key -Value $cfg[$key]
    }
}

# --- Prerequisites -----------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI not found. Install from https://aka.ms/installazurecliwindows"
    Read-Host "Press Enter to close"
    exit 1
}

az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors 2>$null
az bicep install 2>$null

# --- Subscription selection --------------------------------------------------

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Not logged in. Running az login..."
    az login
    $account = az account show | ConvertFrom-Json
}

Write-Host ""
Write-Host "Current Azure context:"
Write-Host "  Tenant:       $($account.tenantId)"
Write-Host "  Subscription: $($account.name)"
Write-Host "  ID:           $($account.id)"
Write-Host ""
$confirm = Read-Host "Continue with this subscription? [Y/n/list]"

if ($confirm -eq "n") {
    az login
    $account = az account show | ConvertFrom-Json
} elseif ($confirm -eq "list") {
    $subs = az account list --output json | ConvertFrom-Json
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $marker = if ($subs[$i].isDefault) { " (current)" } else { "" }
        Write-Host "  [$i] $($subs[$i].name) - $($subs[$i].id)$marker"
    }
    $choice = Read-Host "Enter number"
    az account set --subscription $subs[$choice].id
    $account = az account show | ConvertFrom-Json
}

Write-Host ""
Write-Host "Deploying to:"
Write-Host "  Subscription: $($account.name) ($($account.id))"
Write-Host "  Resource group: $ResourceGroup ($Location)"
Write-Host "  Tags: Owner=$TagOwner  Environment=$TagEnvironment  Project=$TagProject"
Write-Host ""

# --- SSH Key -----------------------------------------------------------------

if (-not (Test-Path "$SshKeyPath")) {
    Write-Host "Generating SSH key at $SshKeyPath..."
    "", "" | ssh-keygen -t ed25519 -f $SshKeyPath -C $VmName
    if ($LASTEXITCODE -ne 0) {
        Write-Error "SSH key generation failed."
        Read-Host "Press Enter to close"
        exit 1
    }
}
$sshPublicKey = Get-Content "$SshKeyPath.pub" -Raw

# --- Resource Group ----------------------------------------------------------

Write-Host "Ensuring resource group $ResourceGroup exists..."
$ErrorActionPreference = "Continue"
az group create --name $ResourceGroup --location $Location `
    --tags "Owner=$TagOwner" "Environment=$TagEnvironment" "Project=$TagProject" `
    --output none
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create resource group."
    Read-Host "Press Enter to close"
    exit 1
}

# --- Bicep Deployment --------------------------------------------------------

Write-Host ""
Write-Host "Deploying infrastructure..."
$ErrorActionPreference = "Continue"
$deployment = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $bicepFile `
    --parameters vmName=$VmName location=$Location vmSize=$VmSize `
                 adminUsername=$AdminUser sshPublicKey=$sshPublicKey `
                 diskSizeGb=$DiskSizeGb autoShutdownTime=$AutoShutdownTime `
                 cpuIdleThresholdPct=$CpuThresholdPct cpuIdleMinutes=$IdleMinutes `
                 tagOwner=$TagOwner tagEnvironment=$TagEnvironment tagProject=$TagProject `
    --output json | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed."
    Read-Host "Press Enter to close"
    exit 1
}

$publicIp           = $deployment.properties.outputs.publicIpAddress.value
$automationAccount  = $deployment.properties.outputs.automationAccountName.value

Write-Host "Infrastructure deployed. Public IP: $publicIp"

# --- Runbook Content Upload --------------------------------------------------

Write-Host "Uploading shutdown runbook..."
$runbookName = "ShutdownOnIdle"
$runbookContent = @'
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

$rg        = Get-AutomationVariable -Name 'ResourceGroup'
$vmName    = Get-AutomationVariable -Name 'VmName'
$threshold = [double](Get-AutomationVariable -Name 'CpuThreshold')
$idleMins  = [int](Get-AutomationVariable -Name 'IdleMinutes')

# Check VM power state - skip if already deallocated
$vmStatus   = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status
$powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
if ($powerState -ne 'VM running') {
    Write-Output "VM is not running ($powerState). Skipping."
    exit
}

# Query CPU percentage via Azure Monitor REST API
$ctx      = Get-AzContext
$subId    = $ctx.Subscription.Id
$token    = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$end      = [DateTime]::UtcNow
$start    = $end.AddMinutes(-$idleMins)
$timespan = "$($start.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($end.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
$uri      = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$vmName/providers/microsoft.insights/metrics?api-version=2019-07-01&metricnames=Percentage+CPU&timespan=$timespan&interval=PT5M&aggregation=average"
$resp     = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Method Get
$points   = $resp.value[0].timeseries[0].data | Where-Object { $null -ne $_.average }

if (-not $points) {
    Write-Output "No CPU data for the last $idleMins minutes. Skipping."
    exit
}

$avgCpu = ($points | Measure-Object -Property average -Average).Average
Write-Output "Avg CPU last $idleMins min: $([math]::Round($avgCpu, 2))% (threshold: $threshold%)"

if ($avgCpu -lt $threshold) {
    Write-Output "CPU idle - deallocating $vmName in $rg..."
    Stop-AzVM -ResourceGroupName $rg -Name $vmName -Force
    Write-Output "Done."
} else {
    Write-Output "CPU active - VM stays running."
}
'@

$tmpFile = [System.IO.Path]::GetTempFileName() + ".ps1"
[System.IO.File]::WriteAllText($tmpFile, $runbookContent)

$ErrorActionPreference = "Continue"

az automation runbook create `
    --resource-group $ResourceGroup `
    --automation-account-name $automationAccount `
    --name $runbookName `
    --type PowerShell `
    --only-show-errors `
    --output none

# Upload runbook content with retry (create may take a few seconds to propagate)
Write-Host "Uploading runbook content..."
$uploaded = $false
for ($i = 0; $i -lt 12; $i++) {
    if ($i -gt 0) { Start-Sleep -Seconds 5 }
    az automation runbook replace-content `
        --resource-group $ResourceGroup `
        --automation-account-name $automationAccount `
        --name $runbookName `
        --content (Get-Content $tmpFile -Raw) `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) { $uploaded = $true; break }
    Write-Host "  Not ready yet, retrying... ($([int](($i+1)*5))s)"
}

if (-not $uploaded) {
    Write-Host "WARNING: Runbook content upload failed after 60s - skipping."
    Write-Host "         Re-run setup-azure-vm.bat to retry."
} else {
    az automation runbook publish `
        --resource-group $ResourceGroup `
        --automation-account-name $automationAccount `
        --name $runbookName `
        --only-show-errors `
        --output none

    Write-Host "Runbook published."

    # Link the IdleCheck schedule to the runbook
    Write-Host "Linking IdleCheck schedule to runbook..."
    $jobScheduleId = [guid]::NewGuid().ToString()
    az automation job-schedule create `
        --resource-group $ResourceGroup `
        --automation-account-name $automationAccount `
        --job-schedule-id $jobScheduleId `
        --runbook-name $runbookName `
        --schedule-name "IdleCheck" `
        --only-show-errors `
        --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Schedule linked. Runbook will check CPU every 15 minutes."
    } else {
        Write-Host "Note: Schedule link may already exist (re-deployment). Skipping."
    }
}

$ErrorActionPreference = "Stop"
Remove-Item $tmpFile

# --- SSH Config --------------------------------------------------------------

$sshConfig = "$HOME\.ssh\config"
if (-not (Test-Path $sshConfig)) { New-Item $sshConfig -ItemType File | Out-Null }

$existingConfig = Get-Content $sshConfig -Raw -ErrorAction SilentlyContinue
if ($existingConfig -notmatch "Host pi-vm") {
    $sshEntry = "`nHost pi-vm`n    HostName $publicIp`n    User $AdminUser`n    IdentityFile $SshKeyPath`n    StrictHostKeyChecking no`n"
    Add-Content $sshConfig $sshEntry
    Write-Host "Added 'pi-vm' entry to ~/.ssh/config"
} else {
    # Update IP in case it changed
    $updated = $existingConfig -replace "(?<=Host pi-vm\s+HostName )[\d.]+", $publicIp
    Set-Content $sshConfig $updated
    Write-Host "Updated pi-vm IP in ~/.ssh/config"
}

# --- Summary -----------------------------------------------------------------

Write-Host ""
Write-Host "========================================================"
Write-Host " Deployment complete"
Write-Host "========================================================"
Write-Host ""
Write-Host "Public IP:  $publicIp"
Write-Host "SSH:        ssh pi-vm"
Write-Host ""
Write-Host "Next step - install Docker and tmux on the VM:"
Write-Host "  scp setup-vm.sh pi-vm:~/"
Write-Host "  ssh pi-vm 'sudo bash ~/setup-vm.sh'"
Write-Host ""
Write-Host "Add these to your project .env files:"
Write-Host "  AZURE_VM_RG=$ResourceGroup"
Write-Host "  AZURE_VM_NAME=$VmName"
Write-Host "  AZURE_VM_USER=$AdminUser"
Write-Host "  AZURE_VM_HOST=$publicIp"
Write-Host "  AZURE_VM_PROJECT_PATH=~/projects/YOUR-PROJECT-NAME"
Write-Host ""
Write-Host "Note: VM auto-shuts down daily at $AutoShutdownTime UTC."
Write-Host "      CPU-idle shutdown: shuts down if avg CPU < $CpuThresholdPct% for $IdleMinutes min."
Write-Host "      Checked every 15 minutes via Azure Automation (ShutdownOnIdle runbook)."
Write-Host ""
Read-Host "Press Enter to close"

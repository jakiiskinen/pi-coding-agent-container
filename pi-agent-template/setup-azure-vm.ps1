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
    [string]$ResourceGroup     = "rg-antti-ai-coding-agent",
    [string]$VmName            = "vm-antti-ai-coding-agent",
    [string]$Location          = "northeurope",
    [string]$VmSize            = "Standard_B4ms",
    [string]$AdminUser         = "azureuser",
    [string]$SshKeyPath        = "$HOME\.ssh\pi-agent-vm",
    [int]   $DiskSizeGb        = 64,
    [string]$AutoShutdownTime  = "2200",
    [string]$TagOwner          = "antti.kiiskinen@adafy.com",
    [string]$TagEnvironment    = "dev",
    [string]$TagProject        = "ai-coding-agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$bicepFile = "$PSScriptRoot\bicep\main.bicep"

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

# --- Bicep What-If preview ---------------------------------------------------

Write-Host ""
Write-Host "Running what-if preview..."
Write-Host ""
$ErrorActionPreference = "Continue"
az deployment group what-if `
    --resource-group $ResourceGroup `
    --template-file $bicepFile `
    --parameters vmName=$VmName location=$Location vmSize=$VmSize `
                 adminUsername=$AdminUser sshPublicKey=$sshPublicKey `
                 diskSizeGb=$DiskSizeGb autoShutdownTime=$AutoShutdownTime `
                 tagOwner=$TagOwner tagEnvironment=$TagEnvironment tagProject=$TagProject
$ErrorActionPreference = "Stop"

Write-Host ""
$proceed = Read-Host "Proceed with deployment? [Y/n]"
if ($proceed -eq "n") {
    Write-Host "Deployment cancelled."
    Read-Host "Press Enter to close"
    exit 0
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
$rg = Get-AutomationVariable -Name 'ResourceGroup'
$vm = Get-AutomationVariable -Name 'VmName'
Write-Output "Deallocating $vm in $rg..."
Stop-AzVM -ResourceGroupName $rg -Name $vm -Force
Write-Output "Done."
'@

$tmpFile = [System.IO.Path]::GetTempFileName() + ".ps1"
[System.IO.File]::WriteAllText($tmpFile, $runbookContent)

$ErrorActionPreference = "Continue"

az automation runbook create `
    --resource-group $ResourceGroup `
    --automation-account-name $automationAccount `
    --name $runbookName `
    --type PowerShell72 `
    --only-show-errors `
    --output none

# Wait for runbook to be available (retry up to 60s)
Write-Host "Waiting for runbook to register..."
$ready = $false
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 5
    $check = az automation runbook show `
        --resource-group $ResourceGroup `
        --automation-account-name $automationAccount `
        --name $runbookName `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Write-Host "  Not ready yet, retrying... ($([int](($i+1)*5))s)"
}

if (-not $ready) {
    Write-Host "WARNING: Runbook not found after 60s - skipping content upload."
    Write-Host "         Re-run setup-azure-vm.bat to retry."
} else {
    az automation runbook replace-content `
        --resource-group $ResourceGroup `
        --automation-account-name $automationAccount `
        --name $runbookName `
        --content (Get-Content $tmpFile -Raw) `
        --only-show-errors

    az automation runbook publish `
        --resource-group $ResourceGroup `
        --automation-account-name $automationAccount `
        --name $runbookName `
        --only-show-errors `
        --output none

    Write-Host "Runbook published."
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
Write-Host "      For CPU-idle shutdown, configure via Azure Portal:"
Write-Host "      Monitor > Alerts > + Create > Metric alert on $VmName"
Write-Host ""
Read-Host "Press Enter to close"

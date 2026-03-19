# ============================================================================
# Azure VM Provisioning Script — Pi Coding Agent
# Run once to create the VM and configure auto-shutdown.
#
# Prerequisites:
#   - Azure CLI installed: https://aka.ms/installazurecliwindows
#   - Logged in: az login
# ============================================================================

param(
    [string]$ResourceGroup  = "pi-agent-rg",
    [string]$VmName         = "pi-agent-vm",
    [string]$Location       = "northeurope",
    [string]$VmSize         = "Standard_B4ms",
    [string]$AdminUser      = "azureuser",
    [string]$SshKeyPath     = "$HOME\.ssh\pi-agent-vm",
    [int]   $DiskSizeGb     = 64,
    # CPU idle shutdown: shut down if avg CPU below this % for $IdleWindowMinutes
    [int]   $IdleCpuPercent = 5,
    [int]   $IdleWindowMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Prerequisites ─────────────────────────────────────────────────────────────

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI not found. Install from https://aka.ms/installazurecliwindows"
    exit 1
}

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Not logged in. Running az login..."
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Host "Subscription: $($account.name) ($($account.id))"
$subscriptionId = $account.id

# ── SSH Key ───────────────────────────────────────────────────────────────────

if (-not (Test-Path "$SshKeyPath")) {
    Write-Host "Generating SSH key at $SshKeyPath..."
    ssh-keygen -t ed25519 -f $SshKeyPath -N "" -C $VmName
}

# ── Resource Group ────────────────────────────────────────────────────────────

Write-Host "Creating resource group $ResourceGroup in $Location..."
az group create --name $ResourceGroup --location $Location --output none

# ── Virtual Machine ───────────────────────────────────────────────────────────

Write-Host "Creating VM $VmName ($VmSize) — this takes a few minutes..."
az vm create `
    --resource-group $ResourceGroup `
    --name $VmName `
    --image Ubuntu2404 `
    --size $VmSize `
    --admin-username $AdminUser `
    --ssh-key-values "$SshKeyPath.pub" `
    --public-ip-sku Standard `
    --public-ip-address-allocation static `
    --os-disk-size-gb $DiskSizeGb `
    --os-disk-sku Premium_LRS `
    --output none

$publicIp = az network public-ip show `
    --resource-group $ResourceGroup `
    --name "${VmName}PublicIP" `
    --query ipAddress -o tsv

$vmResourceId = az vm show `
    --resource-group $ResourceGroup `
    --name $VmName `
    --query id -o tsv

Write-Host "VM created. Public IP: $publicIp"

# ── NSG: SSH only ─────────────────────────────────────────────────────────────

Write-Host "Restricting NSG to SSH only..."
az network nsg rule create `
    --resource-group $ResourceGroup `
    --nsg-name "${VmName}NSG" `
    --name AllowSSH `
    --priority 1000 `
    --protocol Tcp `
    --destination-port-ranges 22 `
    --access Allow `
    --output none

# Remove any default wide-open rules if present
az network nsg rule delete `
    --resource-group $ResourceGroup `
    --nsg-name "${VmName}NSG" `
    --name default-allow-ssh 2>$null

# ── SSH Config on Local Machine ───────────────────────────────────────────────

$sshConfig = "$HOME\.ssh\config"
if (-not (Test-Path $sshConfig)) { New-Item $sshConfig -ItemType File | Out-Null }

$existingConfig = Get-Content $sshConfig -Raw -ErrorAction SilentlyContinue
if ($existingConfig -notmatch "Host pi-vm") {
    Add-Content $sshConfig @"

Host pi-vm
    HostName $publicIp
    User $AdminUser
    IdentityFile $SshKeyPath
    StrictHostKeyChecking no
"@
    Write-Host "Added 'pi-vm' entry to ~/.ssh/config"
}

# ── Automation Account for CPU-Based Shutdown ─────────────────────────────────

$automationName = "${VmName}-auto"
Write-Host "Creating Automation Account $automationName..."

az automation account create `
    --resource-group $ResourceGroup `
    --name $automationName `
    --location $Location `
    --sku Basic `
    --output none

# Enable system-assigned managed identity
az automation account update `
    --resource-group $ResourceGroup `
    --name $automationName `
    --assign-identity "[system]" `
    --output none

$principalId = az automation account show `
    --resource-group $ResourceGroup `
    --name $automationName `
    --query "identity.principalId" -o tsv

# Grant VM Contributor on the VM resource
Write-Host "Assigning VM Contributor role to Automation Account..."
az role assignment create `
    --assignee $principalId `
    --role "Virtual Machine Contributor" `
    --scope $vmResourceId `
    --output none

# ── Shutdown Runbook ──────────────────────────────────────────────────────────

$runbookName = "ShutdownOnIdle"
$runbookContent = @"
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null
Write-Output "Deallocating $VmName due to CPU idle..."
Stop-AzVM -ResourceGroupName '$ResourceGroup' -Name '$VmName' -Force
Write-Output "Done."
"@

$tmpFile = [System.IO.Path]::GetTempFileName() + ".ps1"
$runbookContent | Out-File -FilePath $tmpFile -Encoding utf8

Write-Host "Creating and publishing Runbook $runbookName..."
az automation runbook create `
    --resource-group $ResourceGroup `
    --automation-account-name $automationName `
    --name $runbookName `
    --type PowerShell72 `
    --output none

az automation runbook replace-content `
    --resource-group $ResourceGroup `
    --automation-account-name $automationName `
    --name $runbookName `
    --content (Get-Content $tmpFile -Raw)

az automation runbook publish `
    --resource-group $ResourceGroup `
    --automation-account-name $automationName `
    --name $runbookName `
    --output none

Remove-Item $tmpFile

# ── Webhook for Runbook ───────────────────────────────────────────────────────

$webhookExpiry = (Get-Date).AddYears(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
$webhook = az automation webhook create `
    --resource-group $ResourceGroup `
    --automation-account-name $automationName `
    --runbook-name $runbookName `
    --name "IdleShutdownWebhook" `
    --expiry-time $webhookExpiry `
    --output json | ConvertFrom-Json

$webhookUrl = $webhook.uri

# ── Action Group ──────────────────────────────────────────────────────────────

Write-Host "Creating Monitor Action Group..."
az monitor action-group create `
    --resource-group $ResourceGroup `
    --name "ShutdownActionGroup" `
    --short-name "Shutdown" `
    --webhook-receiver name="ShutdownWebhook" serviceUri=$webhookUrl useCommonAlertSchema=true `
    --output none

$actionGroupId = az monitor action-group show `
    --resource-group $ResourceGroup `
    --name "ShutdownActionGroup" `
    --query id -o tsv

# ── CPU Idle Metric Alert ─────────────────────────────────────────────────────

Write-Host "Creating CPU idle alert (< $IdleCpuPercent% for $IdleWindowMinutes min)..."
az monitor metrics alert create `
    --resource-group $ResourceGroup `
    --name "IdleShutdown" `
    --scopes $vmResourceId `
    --condition "avg Percentage CPU < $IdleCpuPercent" `
    --window-size "${IdleWindowMinutes}m" `
    --evaluation-frequency 5m `
    --severity 3 `
    --action $actionGroupId `
    --description "Deallocate VM when CPU idle for $IdleWindowMinutes minutes" `
    --output none

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================================"
Write-Host " VM provisioning complete"
Write-Host "========================================================"
Write-Host ""
Write-Host "Next step — install Docker and tmux on the VM:"
Write-Host "  scp `"$($PSScriptRoot)\setup-vm.sh`" pi-vm:~/"
Write-Host "  ssh pi-vm 'sudo bash ~/setup-vm.sh'"
Write-Host ""
Write-Host "Add these values to your project .env files:"
Write-Host "  AZURE_VM_RG=$ResourceGroup"
Write-Host "  AZURE_VM_NAME=$VmName"
Write-Host "  AZURE_VM_USER=$AdminUser"
Write-Host "  AZURE_VM_HOST=$publicIp"
Write-Host "  AZURE_VM_PROJECT_PATH=~/projects/<your-project-name>"
Write-Host ""
Read-Host "Press Enter to close"

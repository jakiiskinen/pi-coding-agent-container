# =============================================================================
# Personal defaults for setup-azure-vm.ps1
# Copy this file to setup-azure-vm.config.ps1 and fill in your values.
# setup-azure-vm.config.ps1 is gitignored.
# All values can also be overridden at runtime:
#   .\setup-azure-vm.ps1 -ResourceGroup my-rg -TagOwner me@example.com
# =============================================================================

@{
    ResourceGroup    = "rg-pi-coding-agent"
    VmName           = "vm-pi-coding-agent"
    Location         = "northeurope"
    VmSize           = "Standard_B4ms"
    AdminUser        = "azureuser"
    SshKeyPath       = "$HOME\.ssh\pi-agent-vm"
    DiskSizeGb       = 64
    AutoShutdownTime = "2200"
    # Shut down if avg CPU stays below CpuThresholdPct% for IdleMinutes minutes
    CpuThresholdPct  = 5
    IdleMinutes      = 30
    TagOwner         = "your-email@example.com"
    TagEnvironment   = "dev"
    TagProject       = "ai-coding-agent"
}

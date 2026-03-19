param([switch]$Local)

trap {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $dir

# Load .env variables into the session
if (Test-Path "$dir\.env") {
    Get-Content "$dir\.env" | ForEach-Object {
        if ($_ -match '^\s*([^#=][^=]*)\s*=\s*(.*)\s*$') {
            [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
        }
    }
}

# --- LOCAL CONTAINER MODE ----------------------------------------------------
if ($Local) {

    # Ensure Docker Desktop Linux engine is ready
    $dockerPipe = "\\.\pipe\dockerDesktopLinuxEngine"
    if (-not (Test-Path $dockerPipe)) {
        Write-Host "Docker is not running. Starting Docker Desktop..."
        Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -WindowStyle Minimized

        Write-Host "Waiting for Docker to be ready..."
        $timeout = 90
        $elapsed = 0
        while (-not (Test-Path $dockerPipe)) {
            Start-Sleep -Seconds 3
            $elapsed += 3
            if ($elapsed -ge $timeout) {
                Write-Error "Docker did not start within $timeout seconds. Please start Docker Desktop manually and try again."
                Read-Host "Press Enter to close"
                exit 1
            }
        }
        Write-Host "Docker is ready."
    }

    # Check for Pi updates and rebuild if needed
    Write-Host "Checking for Pi updates..."
    try {
        $installedVersion = docker run --rm local/pi-coding-agent:latest --version 2>$null
        $latestVersion = (Invoke-RestMethod "https://registry.npmjs.org/@mariozechner/pi-coding-agent/latest").version
        if ($installedVersion -ne $latestVersion) {
            Write-Host "Update available: $installedVersion -> $latestVersion. Rebuilding image..."
            docker compose build --no-cache
            Write-Host "Image updated to $latestVersion."
        } else {
            Write-Host "Pi is up to date ($installedVersion)."
        }
    } catch {
        Write-Host "Could not check for updates, skipping."
    }

    # Clean up orphaned containers from previous runs
    docker compose down --remove-orphans 2>$null

    wt new-tab -d $dir --title "Pi Agent (Local)" powershell -NoExit -Command "docker compose run --rm pi-agent" `; split-pane -V -d "$dir\workspace" --title "Workspace (Local)" powershell

    code "$dir\workspace"

# --- AZURE VM MODE (DEFAULT) -------------------------------------------------
} else {

    $vmRg      = $env:AZURE_VM_RG
    $vmName    = $env:AZURE_VM_NAME
    $vmUser    = $env:AZURE_VM_USER
    $vmHost    = $env:AZURE_VM_HOST
    $vmPath    = $env:AZURE_VM_PROJECT_PATH
    $session   = Split-Path -Leaf $dir

    if (-not $vmRg -or -not $vmName -or -not $vmHost -or -not $vmPath) {
        Write-Error "Azure VM not configured. Add AZURE_VM_RG, AZURE_VM_NAME, AZURE_VM_USER, AZURE_VM_HOST, AZURE_VM_PROJECT_PATH to .env - or run start-pi-local.bat instead."
        Read-Host "Press Enter to close"
        exit 1
    }

    # Check VM power state and start if needed
    Write-Host "Checking Azure VM status..."
    $vmState = az vm show --resource-group $vmRg --name $vmName --show-details --query "powerState" -o tsv 2>$null

    if ($vmState -ne "VM running") {
        Write-Host "VM is $vmState. Starting..."
        az vm start --resource-group $vmRg --name $vmName
        Write-Host "Waiting for SSH..."
    }

    # Wait until SSH is available
    $timeout = 120
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        $test = Test-NetConnection -ComputerName $vmHost -Port 22 -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) { break }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    if ($elapsed -ge $timeout) {
        Write-Error "VM SSH not available after $timeout seconds. Please check the Azure portal."
        Read-Host "Press Enter to close"
        exit 1
    }
    Write-Host "VM is ready."

    # Check for Pi updates on VM and rebuild image if needed
    Write-Host "Checking for Pi updates..."
    try {
        $installedVersion = ssh pi-vm "docker run --rm local/pi-coding-agent:latest --version 2>/dev/null"
        $latestVersion = (Invoke-RestMethod "https://registry.npmjs.org/@mariozechner/pi-coding-agent/latest").version
        if ($installedVersion -ne $latestVersion) {
            Write-Host "Update available: $installedVersion -> $latestVersion. Rebuilding image on VM..."
            ssh pi-vm "docker compose -f $vmPath/docker-compose.yml build --no-cache"
            Write-Host "Image updated to $latestVersion."
        } else {
            Write-Host "Pi is up to date ($installedVersion)."
        }
    } catch {
        Write-Host "Could not check for updates, skipping."
    }

    # Open Windows Terminal:
    #   Left pane  — SSH into VM, attach to (or create) a tmux session for this project
    #   Right pane — local workspace folder in PowerShell (same files via any sync, or just for reference)
    $sshCmd = "ssh -t pi-vm 'if tmux has-session -t $session 2>/dev/null; then tmux attach-session -t $session; else tmux new-session -s $session -c $vmPath -- docker compose run --rm pi-agent; fi'"

    wt new-tab --title "Pi Agent (VM: $session)" powershell -NoExit -Command $sshCmd `; split-pane -V -d "$dir\workspace" --title "Workspace" powershell

    # Open VS Code connected to the VM workspace
    code --remote "ssh-remote+pi-vm" "$vmPath/workspace"
}

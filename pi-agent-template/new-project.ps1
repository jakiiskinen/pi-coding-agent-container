param(
    [string]$ProjectPath
)

trap {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$templateDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load values from template .env (shared credentials/Azure settings)
$templateEnv = @{}
if (Test-Path "$templateDir\.env") {
    Get-Content "$templateDir\.env" | ForEach-Object {
        if ($_ -match '^\s*([^#=][^=]*)\s*=\s*(.+)\s*$') {
            $templateEnv[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
}

if (-not $ProjectPath) {
    $ProjectPath = Read-Host "Enter new project path"
}

$target = Resolve-Path -Path $ProjectPath -ErrorAction SilentlyContinue
if (-not $target) {
    $target = $ProjectPath
}

if (Test-Path $target) {
    Write-Error "Directory already exists: $target"
    Read-Host "Press Enter to close"
    exit 1
}

$projectName = Split-Path -Leaf $target

# --- Local setup -------------------------------------------------------------

Write-Host "Creating local project at: $target"
New-Item -ItemType Directory -Path $target | Out-Null

$files = @("Dockerfile", "docker-compose.yml", ".env.example", "start-pi.bat", "start-pi-local.bat", "start-pi.ps1")
foreach ($file in $files) {
    Copy-Item "$templateDir\$file" "$target\$file"
}

New-Item -ItemType Directory -Path "$target\workspace" | Out-Null
New-Item -ItemType Directory -Path "$target\.pi-data"  | Out-Null

# Always create .env from .env.example as base
Copy-Item "$target\.env.example" "$target\.env"

# --- Fill .env with all available values -------------------------------------

# Fills a key in .env only if it is currently empty
function Set-EnvValue {
    param([string]$FilePath, [string]$Key, [string]$Value)
    if (-not $Value) { return }
    $content = Get-Content $FilePath -Raw
    if ($content -match "(?m)^$Key=\s*$") {
        $content = $content -replace "(?m)^$Key=\s*$", "$Key=$Value"
        $content | Set-Content $FilePath -NoNewline
        Write-Host "  $Key"
    }
}

Write-Host "Filling .env..."

$envFile = "$target\.env"

# From template .env (shared credentials and Azure VM settings)
foreach ($key in $templateEnv.Keys) {
    Set-EnvValue $envFile $key $templateEnv[$key]
}

# From local git config
Set-EnvValue $envFile "GIT_NAME"     (git config --global user.name      2>$null)
Set-EnvValue $envFile "GIT_EMAIL"    (git config --global user.email     2>$null)
Set-EnvValue $envFile "GIT_GPG_KEY"  (git config --global user.signingkey 2>$null)
Set-EnvValue $envFile "GIT_GPG_SIGN" (git config --global commit.gpgsign  2>$null)

# Project-specific (always set)
$remotePath = "~/projects/$projectName"
$content = Get-Content $envFile -Raw
$content = $content -replace "(?m)^AZURE_VM_PROJECT_PATH=.*$", "AZURE_VM_PROJECT_PATH=$remotePath"
$content | Set-Content $envFile -NoNewline
Write-Host "  AZURE_VM_PROJECT_PATH=$remotePath"

Write-Host "Local project created."

# --- Remote setup (if Azure VM is configured) --------------------------------

$vmHost = $templateEnv["AZURE_VM_HOST"]

if ($vmHost) {
    Write-Host ""
    Write-Host "Azure VM detected. Setting up remote project..."

    # Resolve ~ to absolute path so it works in all contexts (tmux -c, docker PWD, etc.)
    $remotePath = (ssh pi-vm "echo $remotePath").Trim()

    # Create directory structure on VM
    ssh pi-vm "mkdir -p $remotePath/workspace $remotePath/.pi-data"

    # Copy files to VM
    $remoteFiles = @("Dockerfile", "docker-compose.yml", ".env.example")
    foreach ($file in $remoteFiles) {
        scp "$templateDir\$file" "pi-vm:$remotePath/$file"
    }

    # Copy the filled .env to VM
    scp $envFile "pi-vm:$remotePath/.env"
    ssh pi-vm "chmod 600 $remotePath/.env"
    Write-Host "Copied .env to VM."

    # Build Pi agent image on VM if not already built
    Write-Host "Checking Pi agent image on VM..."
    $imageExists = ssh pi-vm "docker images -q local/pi-coding-agent:latest 2>/dev/null"
    if (-not $imageExists) {
        Write-Host "Building Pi agent image on VM (this takes a few minutes)..."
        ssh pi-vm "docker compose -f $remotePath/docker-compose.yml build"
        Write-Host "Image built."
    } else {
        Write-Host "Image already exists on VM."
    }

    Write-Host "Remote project created at $remotePath"
} else {
    Write-Host ""
    Write-Host "No Azure VM configured in .env - skipping remote setup."
    Write-Host "Add AZURE_VM_HOST to the template .env to enable this."
}

# --- Done --------------------------------------------------------------------

Write-Host ""
Write-Host "Done. Opening terminal in $target"
wt new-tab -d $target

param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath
)

$templateDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Resolve-Path -Path $ProjectPath -ErrorAction SilentlyContinue
if (-not $target) {
    $target = $ProjectPath
}

if (Test-Path $target) {
    Write-Error "Directory already exists: $target"
    exit 1
}

Write-Host "Creating project at: $target"
New-Item -ItemType Directory -Path $target | Out-Null

# Copy template files
$files = @("Dockerfile", "docker-compose.yml", ".env.example", "start-pi.bat", "start-pi.ps1")
foreach ($file in $files) {
    Copy-Item "$templateDir\$file" "$target\$file"
}

# Create required directories
New-Item -ItemType Directory -Path "$target\workspace" | Out-Null
New-Item -ItemType Directory -Path "$target\.pi-data" | Out-Null

# Copy .env from template directory if it exists, otherwise fall back to example
if (Test-Path "$templateDir\.env") {
    Copy-Item "$templateDir\.env" "$target\.env"
    Write-Host "Copied .env from template."
} else {
    Copy-Item "$target\.env.example" "$target\.env"
    Write-Host "No .env found in template dir - copied from .env.example, please fill in your credentials."
}

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  1. Put your project files in $target\workspace\"
Write-Host "  2. Run start-pi.bat to launch the agent"

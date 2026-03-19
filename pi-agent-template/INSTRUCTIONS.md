# Pi Coding Agent — Setup & Usage Instructions

## Prerequisites

- Docker Desktop installed and running
- Windows Terminal installed
- Azure CLI installed (for cloud mode): https://aka.ms/installazurecliwindows
- VS Code with Remote-SSH extension (for cloud mode)

---

## Modes

| Mode | When to use | Launch with |
|---|---|---|
| **Cloud (default)** | Day-to-day work, long-running sessions | `start-pi.bat` |
| **Local** | Offline, debugging, problem solving | `start-pi-local.bat` |

---

## One-Time Setup: Azure VM (Cloud Mode)

### 1. Provision the VM

Double-click `setup-azure-vm.bat` (or run `setup-azure-vm.ps1` in PowerShell).

This creates:
- Ubuntu 24.04 VM (Standard B4ms, 4 vCPU / 16 GB)
- Static public IP, SSH-only firewall
- Azure Automation account with CPU idle shutdown (< 5% for 30 min → deallocate)

At the end it prints the values to add to your `.env`.

### 2. Install software on the VM

```powershell
scp setup-vm.sh pi-vm:~/
ssh pi-vm "sudo bash ~/setup-vm.sh"
```

Installs Docker Engine, tmux, git, Python 3, Azure CLI.

### 3. Configure template `.env`

Fill in the Azure section in the template's `.env`:

```
AZURE_VM_RG=pi-agent-rg
AZURE_VM_NAME=pi-agent-vm
AZURE_VM_USER=azureuser
AZURE_VM_HOST=<static-public-ip>
AZURE_VM_PROJECT_PATH=    # set per-project by new-project.bat
```

From this point, new projects are automatically set up on the VM too.

---

## Creating a New Project

Double-click `new-project.bat`, enter the full local path (e.g. `C:\git\MyProject`).

The script:
1. Creates the local project folder with all config files
2. Prompts you to confirm your git identity, Anthropic API key, and GitHub token
3. If Azure VM is configured — also creates the project folder on the VM, copies config, and builds the Pi image if not already present
4. If Azure VM is configured — sets your git identity in the VM's **global** git config (`~/.gitconfig`), so the workspace shell can run git commands outside the container. This affects all projects on the VM.
5. Sets `AZURE_VM_PROJECT_PATH` in the local `.env` automatically
6. Opens a terminal in the new project folder

Then clone your repo into the workspace folder:

```powershell
cd workspace
git clone <repo-url> .
```

---

## Starting the Agent

### Cloud mode (default)

Double-click `start-pi.bat`. The script:
1. Checks if the Azure VM is running — starts it if deallocated
2. Waits for SSH to be available
3. Checks for Pi updates on the VM — auto-rebuilds image if newer version available
4. Opens Windows Terminal:
   - **Left pane** — SSH into VM → tmux session for this project → run Pi agent
   - **Right pane** — SSH session into VM workspace folder
5. Opens VS Code connected to the VM workspace via Remote-SSH

### Local mode

Double-click `start-pi-local.bat`. The script:
1. Starts Docker Desktop if not running
2. Checks for Pi updates — auto-rebuilds image if newer version available
3. Opens Windows Terminal:
   - **Left pane** — Pi agent in local Docker container
   - **Right pane** — local workspace folder in PowerShell
4. Opens VS Code in local workspace folder

---

## tmux Session Management (Cloud Mode)

Each project gets a named tmux session on the VM (named after the project folder).

```bash
# List running sessions
tmux ls

# Detach from session (leaves Pi running)
Ctrl+B, D

# Reattach to a session
tmux attach -t my-project

# Stop a session
tmux kill-session -t my-project
```

Sessions survive SSH disconnects and laptop sleep — Pi keeps working.

---

## Project Folder Structure

```
MyProject\
  .env                    # Credentials and VM config (never commit this)
  .env.example            # Credential template
  .gitignore              # Excludes .env, workspace/, .pi-data/
  docker-compose.yml      # Container configuration
  Dockerfile              # Image definition
  start-pi.bat            # Launch cloud mode (default)
  start-pi-local.bat      # Launch local container mode
  start-pi.ps1            # Called by both bat files
  workspace\              # Your project files (clone repos here)
  .pi-data\               # Pi agent sessions, config, auth (local mode only)
```

---

## Credentials (.env)

```
GITHUB_TOKEN=           # GitHub Personal Access Token (scopes: repo, workflow)
ANTHROPIC_API_KEY=      # Anthropic API key (sk-ant-...)
GIT_NAME=               # Your name for git commits
GIT_EMAIL=              # Your email for git commits
GIT_GPG_SIGN=false      # GPG commit signing (leave false unless needed)

AZURE_VM_RG=            # Azure resource group name
AZURE_VM_NAME=          # VM name
AZURE_VM_USER=azureuser # SSH username
AZURE_VM_HOST=          # Static public IP
AZURE_VM_PROJECT_PATH=  # Project path on VM (set automatically by new-project.bat)
```

---

## Security

**Local mode:** Container can only read/write `workspace/` and `.pi-data/` on the host.

**Cloud mode:** Pi agent runs on the Azure VM. The VM is accessible via SSH key only, with no open ports other than 22. The local `workspace/` folder is for reference — actual work happens on the VM.

---

## Updating Pi

Both modes check for Pi updates automatically on each launch and rebuild the image if a newer version is available.

To force a rebuild manually:

**Cloud mode:**
```bash
ssh pi-vm
cd ~/projects/<project-name>
docker compose build --no-cache
```

**Local mode:** Delete the local image, then launch normally:
```powershell
docker rmi local/pi-coding-agent:latest
```

---

## Update Reference

| What changed | Cloud mode | Local mode |
|---|---|---|
| Pi new version | Auto on next start | Auto on next start |
| Template config files changed | Copy updated files to project folders manually | Same |
| Start fresh on a project | Delete local folder + SSH to VM and delete remote folder, then re-run `new-project.bat` | Delete local folder, re-run `new-project.bat` |

---

## Troubleshooting

**VM does not start**
Check Azure portal for VM status. Ensure `az login` is current (`az account show`).

**SSH not available after VM starts**
Wait 30–60 seconds after `az vm start` completes, then retry. If persistent, check NSG rules in Azure portal.

**Error on local startup: `file exists` or network error**
A previous run did not clean up. In the project folder:
```powershell
docker compose down
```
If the error persists, delete `.pi-data\agent` and retry.

**Pi asks to log in / authentication error**
Check that `ANTHROPIC_API_KEY` is set correctly in `.env`.

**Git push fails**
Check that `GITHUB_TOKEN` is set in `.env` with `repo` scope.

**Pi update available but rebuild fails on VM**
SSH into the VM and run manually:
```bash
cd ~/projects/<project-name>
docker compose build --no-cache
```

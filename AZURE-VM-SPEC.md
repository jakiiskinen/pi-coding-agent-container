# Azure VM — Pi Coding Agent Spec

## Overview

Run Pi coding agent sessions in Azure on a Linux VM, allowing multiple long-running parallel sessions that persist independently of the local laptop. The VM starts automatically when needed and shuts down when idle to minimize cost.

---

## Architecture

```
Local laptop (Windows 11)
  └── start-pi.bat
        ├── Ensures Azure VM is running (starts it if not)
        ├── Waits for SSH to be available
        └── Opens Windows Terminal
              ├── Left pane:  SSH → tmux session → Pi agent container
              └── Right pane: VS Code Remote-SSH → workspace folder

Azure VM (Linux)
  ├── Docker (runs Pi agent containers)
  ├── tmux (keeps sessions alive after disconnect)
  └── Azure Monitor → auto-deallocate on CPU idle
```

---

## Azure VM

| Property | Value |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Size | Standard B4ms (4 vCPU, 16 GB RAM) |
| Disk | 64 GB Premium SSD |
| Region | North Europe (or closest to user) |
| Public IP | Static |
| Authentication | SSH key only (no password) |

**B4ms** gives comfortable headroom for 3-4 parallel Pi sessions. Downsize to **B2ms** (2 vCPU, 8 GB) if typically running 1-2 sessions.

---

## VM Software

- **Docker Engine** (not Docker Desktop) + Docker Compose plugin
- **tmux** — persistent terminal sessions
- **git**
- **Azure CLI** (`az`) — for VM management from within the VM if needed
- **Python 3 + pip** — already in the container, but useful on the host too

---

## Project Structure on VM

Each project lives in its own folder under a common root:

```
~/projects/
  ├── project-a/
  │     ├── docker-compose.yml
  │     ├── .env
  │     ├── workspace/       ← project files
  │     └── .pi-data/        ← Pi agent sessions and config
  ├── project-b/
  │     └── ...
  └── pi-agent-template/     ← template for new projects
        └── new-project.sh   ← Linux equivalent of new-project.ps1
```

---

## Session Management with tmux

Each project gets a named tmux session. Pi agent runs inside Docker within that session.

```bash
# Start a new project session
tmux new -s project-a
cd ~/projects/project-a
docker compose run --rm pi-agent

# Detach (session keeps running)
Ctrl+B, D

# List running sessions
tmux ls

# Reattach
tmux attach -t project-a

# Stop a session
tmux kill-session -t project-a
```

Sessions survive SSH disconnects, laptop sleep, and network interruptions.

---

## Auto-Shutdown on CPU Idle

### Mechanism

Azure Monitor watches the VM's CPU metric. When CPU stays below threshold for a sustained period, an Automation Runbook deallocates the VM.

### Configuration

| Setting | Value |
|---|---|
| CPU threshold | < 5% |
| Sustained duration | 30 minutes |
| Action | Deallocate VM (not delete — disk and IP are preserved) |
| Check interval | Every 5 minutes |

### Azure Resources Required

- **Azure Monitor** metric alert rule on CPU percentage
- **Azure Automation Account** with a Runbook that calls `az vm deallocate`
- **Managed Identity** on the VM with `Virtual Machine Contributor` role

### Caveat

CPU idle detection works well when Pi is actively running a task (high CPU) vs waiting (near zero). However, a tmux session with a running Pi container that is simply waiting for user input will also show near-zero CPU and will trigger shutdown.

**Mitigation:** Before leaving a long-running task unattended, ensure Pi is actively working, not waiting for input. The 30-minute window gives enough buffer for short pauses.

---

## Auto-Startup from Laptop

### Changes to start-pi.ps1

The startup script gains a new first step: ensure the Azure VM is running before proceeding.

**Flow:**
```
1. Check Azure VM power state via az CLI
2. If deallocated → az vm start → wait for SSH to be available
3. If already running → proceed immediately
4. Open Windows Terminal:
     Left pane:  SSH into VM → attach or create tmux session
     Right pane: VS Code Remote-SSH → workspace folder on VM
```

### Requirements on local machine

- **Azure CLI** (`az`) installed and logged in (`az login`)
- **SSH key** configured for the VM (`~/.ssh/`)
- **VS Code Remote-SSH** extension installed

### Environment variables to add to local .env or PowerShell profile

```
AZURE_VM_RG=my-resource-group
AZURE_VM_NAME=my-pi-vm
AZURE_VM_USER=azureuser
AZURE_VM_HOST=<static-public-ip>
```

---

## VS Code Integration

VS Code Remote-SSH connects directly to the VM and opens the workspace folder. All editing, file browsing, and terminal access happen on the VM — no file syncing needed.

```
Local VS Code → SSH tunnel → VM workspace folder
```

Add the VM to `~/.ssh/config` on the laptop:

```
Host pi-vm
    HostName <static-public-ip>
    User azureuser
    IdentityFile ~/.ssh/pi-vm-key
```

Then in VS Code: `Remote-SSH: Connect to Host → pi-vm`.

---

## Cost Estimate

Based on North Europe pricing, pay-as-you-go:

| Item | Cost |
|---|---|
| B4ms VM (per hour running) | ~€0.19/hour |
| B2ms VM (per hour running) | ~€0.10/hour |
| Premium SSD 64 GB (always) | ~€10/month |
| Static public IP (always) | ~€3/month |
| Azure Monitor + Automation | ~€1-2/month |

**Example:** 8 hours/day active, 22 working days/month on B4ms:
`(8h × 22 days × €0.19) + €10 + €3 ≈ €46/month`

Deallocated VM only pays for disk and IP — no compute cost.

---

## Security

- SSH key authentication only — no passwords
- Pi agent container isolated to `workspace/` and `.pi-data/` on the VM (same as local)
- `.env` with API keys stored on VM with `chmod 600`
- Azure NSG (Network Security Group) restricts inbound to SSH (port 22) only
- No public HTTP/HTTPS ports exposed

---

## Implementation Steps

1. **Provision VM** — create VM, static IP, NSG, SSH key in Azure portal or via `az` CLI
2. **Install software** — Docker Engine, tmux, git on the VM
3. **Copy template** — transfer `pi-agent-template/` to VM, set up `.env`
4. **Build image** — `docker compose build` on the VM
5. **Configure auto-shutdown** — set up Azure Monitor alert + Automation Runbook
6. **Update start-pi.ps1** — add VM start logic and SSH-based terminal panes
7. **Configure VS Code Remote-SSH** — add SSH config entry on laptop
8. **Test** — full start-to-finish from cold (deallocated) VM

---

## Out of Scope

- Multi-user access
- Container orchestration (Kubernetes)
- Persistent container state beyond workspace and .pi-data volumes
- Automatic project creation on the VM (manual step via SSH)

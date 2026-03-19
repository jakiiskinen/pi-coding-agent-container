#!/bin/bash
# ============================================================================
# VM Software Setup Script — Pi Coding Agent
# Run once on the Azure VM after provisioning:
#   scp setup-vm.sh pi-vm:~/
#   ssh pi-vm 'sudo bash ~/setup-vm.sh'
# ============================================================================

set -e

ACTUAL_USER=${SUDO_USER:-$USER}
HOME_DIR=$(eval echo "~$ACTUAL_USER")

echo "Setting up Pi coding agent environment for user: $ACTUAL_USER"

# ── System update ─────────────────────────────────────────────────────────────

echo "Updating system packages..."
apt-get update -q
apt-get upgrade -y -q

# ── Docker Engine ─────────────────────────────────────────────────────────────

echo "Installing Docker Engine..."
apt-get install -y -q ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin

usermod -aG docker "$ACTUAL_USER"
systemctl enable docker
systemctl start docker

echo "Docker installed."

# ── Tools ─────────────────────────────────────────────────────────────────────

echo "Installing tmux, git, python3..."
apt-get install -y -q tmux git python3 python3-pip python3-venv

# ── Azure CLI ─────────────────────────────────────────────────────────────────

echo "Installing Azure CLI..."
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# ── Project directory ─────────────────────────────────────────────────────────

echo "Creating ~/projects directory..."
sudo -u "$ACTUAL_USER" mkdir -p "$HOME_DIR/projects"

# ── tmux default config ───────────────────────────────────────────────────────

TMUX_CONF="$HOME_DIR/.tmux.conf"
if [ ! -f "$TMUX_CONF" ]; then
    sudo -u "$ACTUAL_USER" tee "$TMUX_CONF" > /dev/null <<'EOF'
# Enable mouse support
set -g mouse on
# Increase scrollback buffer
set -g history-limit 10000
# Start window and pane numbering at 1
set -g base-index 1
setw -g pane-base-index 1
# Show session name in status bar
set -g status-right "#S"
EOF
    echo "Created ~/.tmux.conf"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "========================================================"
echo " VM setup complete"
echo "========================================================"
echo ""
echo "IMPORTANT: Docker group change requires a new SSH session."
echo "Log out and back in, then verify with: docker run hello-world"
echo ""
echo "Next: create a project on the VM from your laptop:"
echo "  Run new-project.bat and provide a project path."
echo "  The script will also set up the project on the VM."
echo ""

#!/bin/bash
#
# dodo-vps — One command to launch a coding-agent-ready VPS
# https://github.com/dodo-digital/dodo-vps
#
# Run from your laptop:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/setup.sh)"
#
# The script handles everything:
#   1. Creates a Hetzner server via API
#   2. Generates/uses SSH keys
#   3. SSHes in and hardens the server
#   4. Installs Claude Code, Codex, Gemini CLI, OpenCode + all dependencies
#
# Or run directly on an existing VPS:
#   sudo ./setup.sh --on-server
#

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Configuration ────────────────────────────────────────────────────
NEW_USER="${NEW_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
HETZNER_TOKEN="${HETZNER_TOKEN:-}"
SERVER_TYPE="${SERVER_TYPE:-cpx21}"
SERVER_LOCATION="${SERVER_LOCATION:-ash}"
SERVER_NAME="${SERVER_NAME:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
RUN_WIZARD="${RUN_WIZARD:-true}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-true}"
INSTALL_CODEX="${INSTALL_CODEX:-true}"
INSTALL_GEMINI_CLI="${INSTALL_GEMINI_CLI:-true}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-true}"
INSTALL_BUN="${INSTALL_BUN:-true}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-false}"

# Set during execution
SERVER_IP=""
TAILSCALE_IP=""
DODO_SSH_KEY="$HOME/.ssh/dodo-vps_ed25519"

SETUP_LOG="/var/log/dodo-vps-setup.log"

log() { echo -e "${GREEN}[dodo-vps]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }
step() { echo -e "\n${BLUE}${BOLD}── $1 ──${NC}\n"; }

# Run a command quietly — show a one-line status, log full output to file
quiet() {
    local label="$1"; shift
    echo -en "  ${label}... "
    if "$@" >> "$SETUP_LOG" 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
        echo "  See $SETUP_LOG for details"
        return 1
    fi
}

# Add a directory to the user's PATH in both .profile (login shells, cron) and .bashrc (interactive)
# Usage: add_user_path '$HOME/.npm-global/bin'  (single-quoted to prevent expansion)
add_user_path() {
    local path_entry="$1"
    local profile="/home/$NEW_USER/.profile"
    local bashrc="/home/$NEW_USER/.bashrc"
    local export_line="export PATH=\"${path_entry}:\$PATH\""

    # .profile — used by login shells and non-interactive contexts (cron, su -, ssh cmd)
    if ! grep -qF "$path_entry" "$profile" 2>/dev/null; then
        echo "$export_line" >> "$profile"
    fi

    # .bashrc — used by interactive shells (redundant but ensures immediate availability)
    if ! grep -qF "$path_entry" "$bashrc" 2>/dev/null; then
        echo "$export_line" >> "$bashrc"
    fi

    chown "$NEW_USER:$NEW_USER" "$profile" "$bashrc"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    local yn_hint="[Y/n]"
    [ "$default" = "n" ] && yn_hint="[y/N]"
    while true; do
        echo -en "  ${prompt} ${yn_hint}: "
        read -r answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;; [Nn]*) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

# ─── Hetzner API helpers ─────────────────────────────────────────────
hetzner_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -H "Authorization: Bearer $HETZNER_TOKEN" -H "Content-Type: application/json")
    [ -n "$data" ] && args+=(-d "$data")
    curl "${args[@]}" -X "$method" "https://api.hetzner.cloud/v1${endpoint}"
}

# =====================================================================
#  PHASE 1: LOCAL — Create server, handle SSH keys
# =====================================================================

setup_ssh_key() {
    step "SSH Key"

    # Explicit key path takes priority
    if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
        log "Using provided SSH key: $SSH_KEY_PATH"
        DODO_SSH_KEY="$SSH_KEY_PATH"
        return
    fi

    # Reuse existing key if one exists
    if [ -f "$DODO_SSH_KEY" ] && [ -f "${DODO_SSH_KEY}.pub" ]; then
        log "Found existing key: $DODO_SSH_KEY"
        if ask_yes_no "Use this key?" "y"; then
            return
        fi
    fi

    # Generate a dedicated key
    log "Generating dedicated SSH key..."
    ssh-keygen -t ed25519 -f "$DODO_SSH_KEY" -N "" -C "dodo-vps-$(date +%Y%m%d)"
    log "Created: $DODO_SSH_KEY"
}

create_hetzner_server() {
    step "Create Server"

    # Upload SSH key to Hetzner
    log "Uploading SSH key to Hetzner..."
    local pubkey
    pubkey=$(cat "${DODO_SSH_KEY}.pub")
    local key_name="dodo-vps-$(date +%s)"

    local key_response
    key_response=$(hetzner_api POST /ssh_keys "{\"name\":\"$key_name\",\"public_key\":\"$pubkey\"}")

    local ssh_key_id
    ssh_key_id=$(echo "$key_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_key']['id'])" 2>/dev/null)

    if [ -z "$ssh_key_id" ] || [ "$ssh_key_id" = "None" ]; then
        # Key might already exist — try to find it by fingerprint
        local fingerprint
        fingerprint=$(ssh-keygen -lf "${DODO_SSH_KEY}.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')
        ssh_key_id=$(hetzner_api GET "/ssh_keys" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k in data.get('ssh_keys', []):
    if k.get('fingerprint') == '$fingerprint':
        print(k['id']); break
" 2>/dev/null)
        if [ -z "$ssh_key_id" ]; then
            echo "$key_response" >&2
            error "Failed to upload SSH key to Hetzner. Check your API token."
        fi
        log "SSH key already exists on Hetzner (id: $ssh_key_id)"
    else
        log "SSH key uploaded (id: $ssh_key_id)"
    fi

    # Create server
    if [ -z "$SERVER_NAME" ]; then
        SERVER_NAME="agent-vps-$(head -c 4 /dev/urandom | xxd -p)"
    fi

    log "Creating server: $SERVER_NAME ($SERVER_TYPE in $SERVER_LOCATION)..."

    local server_response
    server_response=$(hetzner_api POST /servers "{
        \"name\": \"$SERVER_NAME\",
        \"server_type\": \"$SERVER_TYPE\",
        \"image\": \"ubuntu-24.04\",
        \"location\": \"$SERVER_LOCATION\",
        \"ssh_keys\": [$ssh_key_id],
        \"start_after_create\": true
    }")

    SERVER_IP=$(echo "$server_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])" 2>/dev/null)

    if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "None" ]; then
        echo "$server_response" >&2
        error "Failed to create server. Check your API token and Hetzner account."
    fi

    log "Server created! IP: $SERVER_IP"
}

wait_for_server() {
    step "Waiting for Server"

    log "Waiting for $SERVER_IP to accept SSH connections..."
    local attempts=0
    local max_attempts=60  # 5 minutes

    while [ $attempts -lt $max_attempts ]; do
        if ssh -i "$DODO_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes root@"$SERVER_IP" "echo ok" &>/dev/null; then
            log "Server is ready!"
            return
        fi
        attempts=$((attempts + 1))
        echo -en "\r  Waiting... ${attempts}/${max_attempts} ($(( attempts * 5 ))s)"
        sleep 5
    done
    echo ""
    error "Server did not become reachable after 5 minutes. Check Hetzner console."
}

run_remote_setup() {
    step "Running Setup on Server"

    log "SSHing into $SERVER_IP and running server setup..."
    echo ""

    local script_url="https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/setup.sh"
    local ssh_opts="-i $DODO_SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    # Download script to server first (keeps stdin free for interactive prompts)
    ssh $ssh_opts root@"$SERVER_IP" \
        "curl -fsSL $script_url -o /tmp/dodo-vps-setup.sh && chmod +x /tmp/dodo-vps-setup.sh"

    # Run with -t for pseudo-terminal so interactive prompts work
    ssh -t $ssh_opts root@"$SERVER_IP" \
        "NEW_USER=$NEW_USER INSTALL_DOCKER=$INSTALL_DOCKER INSTALL_CLAUDE_CODE=$INSTALL_CLAUDE_CODE INSTALL_CODEX=$INSTALL_CODEX INSTALL_GEMINI_CLI=$INSTALL_GEMINI_CLI INSTALL_OPENCODE=$INSTALL_OPENCODE INSTALL_BUN=$INSTALL_BUN INSTALL_TAILSCALE=$INSTALL_TAILSCALE bash /tmp/dodo-vps-setup.sh --on-server"
}

run_wizard_local() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Coding Agent VPS Setup           ║${NC}"
    echo -e "${GREEN}║   One command. Four coding agents. Done.  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  This wizard will:"
    echo ""
    echo "    1. Create a cloud server for you on Hetzner"
    echo "    2. Secure it (firewall, brute-force protection, encrypted access)"
    echo "    3. Install Claude Code, Codex, Gemini CLI, and OpenCode"
    echo ""
    echo "  The whole thing takes about 10 minutes. You just follow the prompts."
    echo ""
    echo "  Hetzner is the cloud provider that hosts your server."
    echo "  You'll need a Hetzner account and an API key to continue."
    echo "  Servers start at ~\$4/month and you can delete anytime."
    echo ""

    # ── Hetzner API key ──
    step "Hetzner API Key"

    local token_valid=false
    while [ "$token_valid" = false ]; do
        if ! ask_yes_no "Do you have your Hetzner API key ready?" "y"; then
            echo ""
            echo "  No problem! Here's how to get one:"
            echo ""
            echo "  ${BOLD}1.${NC} Go to ${BLUE}https://console.hetzner.cloud/${NC}"
            echo "     Create a free account if you don't have one."
            echo ""
            echo "  ${BOLD}2.${NC} Once logged in, create a new Project (or use the default one)."
            echo ""
            echo "  ${BOLD}3.${NC} Inside your project, click ${BOLD}Security${NC} in the left sidebar."
            echo ""
            echo "  ${BOLD}4.${NC} Click the ${BOLD}API Tokens${NC} tab, then ${BOLD}Generate API Token${NC}."
            echo ""
            echo "  ${BOLD}5.${NC} Give it a name (like \"dodo-vps\"), select ${BOLD}Read & Write${NC} access,"
            echo "     and click Generate."
            echo ""
            echo "  ${BOLD}6.${NC} ${YELLOW}Copy the token now${NC} — you won't be able to see it again."
            echo ""

            echo -en "  Ready to continue? Press Enter when you have your token... "
            read -r
        fi

        echo ""
        echo "  Your token is only used during this setup and is never saved to disk."
        echo ""
        HETZNER_TOKEN=""
        while [ -z "$HETZNER_TOKEN" ]; do
            echo -en "  Paste your Hetzner API token: "
            read -rs HETZNER_TOKEN
            echo ""
            if [ -z "$HETZNER_TOKEN" ]; then
                echo "  Token can't be empty."
            fi
        done

        # Validate token
        echo -en "  Checking token with Hetzner... "
        local test_response
        test_response=$(hetzner_api GET /servers 2>/dev/null || true)
        if echo "$test_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'servers' in d" 2>/dev/null; then
            echo -e "${GREEN}valid!${NC}"
            token_valid=true
        else
            echo -e "${RED}invalid${NC}"
            echo ""
            echo "  That token didn't work. Let's try again."
            echo ""
        fi
    done

    # ── Server size ──
    step "Server Size"

    echo "  Pick a server size:"
    echo ""
    echo "    1)  Small       —  2 GB /  2 CPU  ~\$6/mo   Light usage"
    echo "    2)  Medium      —  4 GB /  3 CPU  ~\$11/mo  Recommended"
    echo "    3)  Large       —  8 GB /  4 CPU  ~\$19/mo  Heavy usage"
    echo "    4)  Extra Large — 16 GB /  8 CPU  ~\$34/mo  Power user"
    echo ""
    echo -en "  Choice [2]: "
    read -r size_choice
    case "${size_choice:-2}" in
        1) SERVER_TYPE="cpx11" ;; 2) SERVER_TYPE="cpx21" ;;
        3) SERVER_TYPE="cpx31" ;; 4) SERVER_TYPE="cpx41" ;;
        *) SERVER_TYPE="cpx21" ;;
    esac

    # ── Location ──
    step "Server Location"

    echo "  Pick a location:"
    echo ""
    echo "    1)  Ashburn, US (ash)      — US East"
    echo "    2)  Hillsboro, US (hil)    — US West"
    echo "    3)  Nuremberg, DE (nbg1)   — Europe"
    echo "    4)  Helsinki, FI (hel1)    — Europe"
    echo ""
    echo -en "  Choice [1]: "
    read -r loc_choice
    case "${loc_choice:-1}" in
        1) SERVER_LOCATION="ash" ;; 2) SERVER_LOCATION="hil" ;;
        3) SERVER_LOCATION="nbg1" ;; 4) SERVER_LOCATION="hel1" ;;
        *) SERVER_LOCATION="ash" ;;
    esac

    # ── Username ──
    step "User Account"

    echo "  Username for the server (runs your coding agents, not root)."
    echo -en "  Username [ubuntu]: "
    read -r input_user
    if [ -n "$input_user" ]; then
        if [[ "$input_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            NEW_USER="$input_user"
        else
            warn "Invalid username, using default: ubuntu"
        fi
    fi

    # ── Optional tools ──
    step "Coding Agents & Tools"

    echo "  These are always installed: Node.js 22, Homebrew, Bun"
    echo "  Choose which coding agents and tools to install:"
    echo ""

    ask_yes_no "Claude Code? (Anthropic CLI)" "y" && INSTALL_CLAUDE_CODE=true || INSTALL_CLAUDE_CODE=false
    ask_yes_no "Codex? (OpenAI CLI)" "y" && INSTALL_CODEX=true || INSTALL_CODEX=false
    ask_yes_no "Gemini CLI? (Google CLI)" "y" && INSTALL_GEMINI_CLI=true || INSTALL_GEMINI_CLI=false
    ask_yes_no "OpenCode? (open-source agent)" "y" && INSTALL_OPENCODE=true || INSTALL_OPENCODE=false
    echo ""
    ask_yes_no "Docker?" "y" && INSTALL_DOCKER=true || INSTALL_DOCKER=false
    echo ""
    ask_yes_no "Tailscale? (private VPN mesh — access server via secure IP)" "y" && INSTALL_TAILSCALE=true || INSTALL_TAILSCALE=false

    # ── Summary ──
    step "Summary"

    echo "  Server:      $SERVER_TYPE in $SERVER_LOCATION"
    echo "  User:        $NEW_USER"
    echo "  Claude Code: $([ "$INSTALL_CLAUDE_CODE" = true ] && echo "yes" || echo "no")"
    echo "  Codex:       $([ "$INSTALL_CODEX" = true ] && echo "yes" || echo "no")"
    echo "  Gemini CLI:  $([ "$INSTALL_GEMINI_CLI" = true ] && echo "yes" || echo "no")"
    echo "  OpenCode:    $([ "$INSTALL_OPENCODE" = true ] && echo "yes" || echo "no")"
    echo "  Docker:      $([ "$INSTALL_DOCKER" = true ] && echo "yes" || echo "no")"
    echo "  Tailscale:   $([ "$INSTALL_TAILSCALE" = true ] && echo "yes" || echo "no")"
    echo ""

    if ! ask_yes_no "Create the server and start setup?" "y"; then
        echo "  Cancelled."
        exit 0
    fi
}

setup_local_tailscale() {
    step "Tailscale on This Computer"

    # Already installed?
    if command -v tailscale &>/dev/null; then
        log "Tailscale is already installed on this computer"
        if tailscale status &>/dev/null 2>&1; then
            log "Already connected to your Tailscale network"
            return
        fi
        echo "  Tailscale is installed but not connected. Opening it now..."
        if [[ "$(uname)" == "Darwin" ]]; then
            open -a Tailscale 2>/dev/null
        else
            sudo tailscale up
        fi
        return
    fi

    # Install
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS — use Homebrew cask (installs the GUI app + CLI)
        if command -v brew &>/dev/null; then
            log "Installing Tailscale via Homebrew..."
            brew install --cask tailscale
            echo ""
            echo -e "  ${BOLD}Sign in with the same account you used on the server.${NC}"
            echo ""
            open -a Tailscale
            echo "  Waiting for Tailscale to connect..."
            echo -en "  Press Enter once you've signed in... "
            read -r
        else
            echo ""
            echo "  Install Tailscale on this computer to connect to your VPS privately:"
            echo ""
            echo -e "  ${BOLD}Download:${NC} ${BLUE}https://tailscale.com/download/mac${NC}"
            echo ""
            echo "  Sign in with the same account you used on the server."
            echo -en "  Press Enter to continue... "
            read -r
        fi
    else
        # Linux laptop
        log "Installing Tailscale..."
        if curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh 2>/dev/null; then
            bash /tmp/tailscale-install.sh
            rm -f /tmp/tailscale-install.sh
            echo ""
            echo -e "  ${BOLD}Sign in with the same account you used on the server.${NC}"
            echo ""
            sudo tailscale up
        else
            warn "Tailscale download failed — install manually: https://tailscale.com/download"
        fi
    fi

    log "Your VPS and this computer are now on the same private network"
}

setup_local_ssh_alias() {
    step "SSH Shortcut"

    if ! ask_yes_no "Create a quick alias so you can connect with one word? (e.g., type 'vps' instead of the full ssh command)" "y"; then
        return
    fi

    # Detect the user's shell config file
    local shell_rc=""
    case "$SHELL" in
        */zsh)  shell_rc="$HOME/.zshrc" ;;
        */bash) shell_rc="$HOME/.bashrc" ;;
        *)      shell_rc="$HOME/.bashrc" ;;
    esac

    local alias_name=""
    while true; do
        echo -en "  Alias name [vps]: "
        read -r alias_name
        alias_name="${alias_name:-vps}"

        # Validate: only allow simple alphanumeric names
        if ! [[ "$alias_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
            echo "  Invalid alias name. Use letters, numbers, hyphens, or underscores."
            continue
        fi

        # Check for conflicts with existing commands
        if command -v "$alias_name" &>/dev/null; then
            warn "'$alias_name' already exists as a command ($(command -v "$alias_name"))"
            if ! ask_yes_no "Pick a different name?" "y"; then
                # User wants to override — that's their call
                break
            fi
            continue
        fi

        # Check for conflicts with existing aliases
        if alias "$alias_name" &>/dev/null 2>&1; then
            local existing_alias
            existing_alias=$(alias "$alias_name" 2>/dev/null || true)
            warn "'$alias_name' is already aliased: $existing_alias"
            if ! ask_yes_no "Pick a different name?" "y"; then
                break
            fi
            continue
        fi

        # Check if it's already in the shell rc file
        if grep -q "alias ${alias_name}=" "$shell_rc" 2>/dev/null; then
            warn "'$alias_name' is already defined in $(basename "$shell_rc")"
            if ! ask_yes_no "Pick a different name?" "y"; then
                break
            fi
            continue
        fi

        break
    done

    local ssh_cmd
    if [ -n "$TAILSCALE_IP" ]; then
        # Tailscale — connect via private IP (SSH key still needed for auth)
        ssh_cmd="ssh -i $DODO_SSH_KEY $NEW_USER@$TAILSCALE_IP"
    else
        ssh_cmd="ssh -i $DODO_SSH_KEY $NEW_USER@$SERVER_IP"
    fi
    local alias_line="alias ${alias_name}='${ssh_cmd}'"

    # Append to shell config
    {
        echo ""
        echo "# SSH shortcut to coding agent VPS — added by dodo-vps"
        echo "$alias_line"
    } >> "$shell_rc"

    # Load it into the current session
    eval "$alias_line"

    log "Alias '${alias_name}' added to $(basename "$shell_rc")"
    echo ""
    echo "  You can now connect to your server by typing:"
    echo ""
    echo -e "    ${BOLD}${alias_name}${NC}"
    if [ -n "$TAILSCALE_IP" ]; then
        echo ""
        echo "  (connects via Tailscale private network: $TAILSCALE_IP)"
    fi
    echo ""
}

print_completion() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            You're All Set!                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ── Your Server ──"
    echo ""
    echo "  IP address:  $SERVER_IP"
    if [ -n "$TAILSCALE_IP" ]; then
        echo "  Tailscale IP: $TAILSCALE_IP"
    fi
    echo "  Server name: $SERVER_NAME"
    echo "  SSH key:     $DODO_SSH_KEY"
    echo ""
    echo "  ── Manage Your Server ──"
    echo ""
    echo "  Hetzner Cloud Console (start, stop, resize, delete):"
    echo -e "  ${BLUE}https://console.hetzner.cloud/projects${NC}"
    echo ""
    echo "  ── Connect ──"
    echo ""
    if [ -n "$TAILSCALE_IP" ]; then
        echo -e "  ${BOLD}ssh -i $DODO_SSH_KEY $NEW_USER@$TAILSCALE_IP${NC}  (via Tailscale)"
        echo ""
        echo "  Or via public IP:"
        echo -e "  ssh -i $DODO_SSH_KEY $NEW_USER@$SERVER_IP"
    else
        echo -e "  ${BOLD}ssh -i $DODO_SSH_KEY $NEW_USER@$SERVER_IP${NC}"
    fi
    echo ""
    echo "  ── On the Server ──"
    echo ""
    echo "  Set your API keys, then start coding:"
    echo ""
    echo "    export ANTHROPIC_API_KEY=sk-ant-..."
    echo "    cc                  # Claude Code (auto-accept permissions)"
    echo "    claude              # Claude Code (normal mode)"
    echo "    codex / cx          # Codex (cx = full auto)"
    echo "    gemini              # Gemini CLI"
    echo "    opencode            # OpenCode"
    echo ""
    echo "  Pre-configured aliases on the server:"
    echo "    cc     — claude --dangerously-skip-permissions"
    echo "    cx     — codex --full-auto"
    echo "    agent  — launch Claude Code in a background tmux session"
    echo "    ports  — show listening ports"
    echo ""
    echo -e "  ${YELLOW}Tip:${NC} Add API keys to ~/.bashrc on the server so they persist."
    echo ""
    echo "  ── Thanks for using dodo-vps! ──"
    echo ""
    echo -e "  Star on GitHub: ${BLUE}https://github.com/dodo-digital/dodo-vps${NC}"
    echo ""
}

local_main() {
    # Check dependencies
    for cmd in curl ssh ssh-keygen python3; do
        command -v "$cmd" &>/dev/null || error "Missing required tool: $cmd"
    done

    if [ "$RUN_WIZARD" = true ] && [ -t 0 ]; then
        run_wizard_local
    else
        # Headless mode — need HETZNER_TOKEN set
        [ -z "$HETZNER_TOKEN" ] && error "HETZNER_TOKEN required for non-interactive mode"
    fi

    setup_ssh_key
    create_hetzner_server
    wait_for_server
    run_remote_setup

    # Fetch Tailscale IP from server (if installed)
    if [ "$INSTALL_TAILSCALE" = true ]; then
        TAILSCALE_IP=$(ssh -i "$DODO_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NEW_USER@$SERVER_IP" "sudo tailscale ip -4 2>/dev/null" 2>/dev/null || true)
    fi

    # Post-setup: local convenience (only in interactive mode)
    if [ -t 0 ]; then
        if [ "$INSTALL_TAILSCALE" = true ]; then setup_local_tailscale; fi
        setup_local_ssh_alias
    fi

    print_completion
}

# =====================================================================
#  PHASE 2: ON-SERVER — Harden + install everything
# =====================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "On-server setup must run as root"
    fi
}

update_system() {
    log "Updating system packages (this takes a few minutes)..."
    quiet "Updating package lists" apt-get update
    quiet "Upgrading installed packages" apt-get upgrade -y
    quiet "Installing required packages" apt-get install -y \
        curl wget git vim htop tmux ufw fail2ban unzip jq \
        software-properties-common apt-transport-https \
        ca-certificates gnupg lsb-release build-essential \
        python3 python3-pip python3-venv
}

create_user() {
    log "Creating user: $NEW_USER"
    if id "$NEW_USER" &>/dev/null; then
        warn "User $NEW_USER already exists"
        return
    fi
    useradd -m -s /bin/bash "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    # Passwordless sudo — no password was set (SSH key auth only)
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
    chmod 440 "/etc/sudoers.d/$NEW_USER"
    log "User $NEW_USER created (SSH key auth, passwordless sudo)"
}

setup_ssh_hardening() {
    log "Configuring SSH hardening..."
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-dodo-vps-hardening.conf << 'EOF'
# Security hardening applied by dodo-vps
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    if sshd -t >> "$SETUP_LOG" 2>&1; then
        # Ubuntu 24.04 uses "ssh", older versions use "sshd"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
        log "SSH hardened. Root login disabled, key auth only."
    else
        error "sshd config validation failed"
    fi
}

setup_firewall() {
    log "Configuring firewall..."
    {
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow "$SSH_PORT/tcp"
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw --force enable
    } >> "$SETUP_LOG" 2>&1
    log "Firewall enabled (SSH, HTTP, HTTPS)"
}

setup_fail2ban() {
    log "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
    systemctl enable fail2ban >> "$SETUP_LOG" 2>&1
    systemctl start fail2ban >> "$SETUP_LOG" 2>&1
    log "Brute-force protection enabled"
}

setup_swap() {
    log "Setting up swap..."
    if swapon --show | grep -q '/swapfile.img'; then
        warn "Swap already active"
        return
    fi
    TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    SWAP_SIZE_MB=$(( TOTAL_RAM_MB <= 16384 ? TOTAL_RAM_MB : 16384 ))
    if [ -f /swapfile.img ]; then
        chmod 0600 /swapfile.img
    else
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile.img
        chmod 0600 /swapfile.img
    fi
    mkswap /swapfile.img >> "$SETUP_LOG" 2>&1
    swapon /swapfile.img >> "$SETUP_LOG" 2>&1
    grep -q '/swapfile.img' /etc/fstab || echo '/swapfile.img none swap sw 0 0' >> /etc/fstab
    sysctl vm.swappiness=10 >> "$SETUP_LOG" 2>&1
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    log "Swap configured (${SWAP_SIZE_MB}MB)"
}

setup_auto_updates() {
    log "Enabling automatic security updates..."
    quiet "Installing auto-update tools" apt-get install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable unattended-upgrades >> "$SETUP_LOG" 2>&1
    systemctl start unattended-upgrades >> "$SETUP_LOG" 2>&1
    log "Auto-updates enabled"
}

install_homebrew() {
    log "Installing Homebrew (this takes a couple minutes)..."
    if su - "$NEW_USER" -c 'command -v brew' &>/dev/null; then log "Already installed"; return; fi

    # Download installer to file
    if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh 2>> "$SETUP_LOG"; then
        warn "Homebrew download failed — continuing without it"
        return 0
    fi
    chmod +r /tmp/brew-install.sh

    # Homebrew REFUSES to run as root — must install as the service user
    echo -en "  Installing Homebrew... "
    if su - "$NEW_USER" -c "NONINTERACTIVE=1 /bin/bash /tmp/brew-install.sh" >> "$SETUP_LOG" 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
        echo "  Check $SETUP_LOG for details"
        rm -f /tmp/brew-install.sh
        warn "Homebrew install failed — continuing without it"
        return
    fi
    rm -f /tmp/brew-install.sh

    # Set up PATH for the user's shell — brew shellenv sets PATH, MANPATH, INFOPATH
    for file in "/home/$NEW_USER/.profile" "/home/$NEW_USER/.bashrc"; do
        if ! grep -q 'linuxbrew' "$file" 2>/dev/null; then
            echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$file"
        fi
    done
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.profile" "/home/$NEW_USER/.bashrc"

    echo -en "  Installing compiler tools... "
    if su - "$NEW_USER" -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew install gcc' >> "$SETUP_LOG" 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed (non-critical)${NC}"
    fi

    log "Homebrew installed"
}

install_node() {
    log "Installing Node.js 22..."
    quiet "Adding Node.js repository" bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
    quiet "Installing Node.js" apt-get install -y nodejs

    # Set up npm global prefix so user can `npm install -g` without root
    su - "$NEW_USER" -c 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global' >> "$SETUP_LOG" 2>&1
    add_user_path '$HOME/.npm-global/bin'

    log "Node.js $(node --version) installed"
}

install_bun() {
    log "Installing Bun runtime..."
    if ! curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh 2>> "$SETUP_LOG"; then
        warn "Bun download failed — install manually later"
        return 0
    fi
    quiet "Installing Bun" su - "$NEW_USER" -c "bash /tmp/bun-install.sh"
    rm -f /tmp/bun-install.sh
    add_user_path '$HOME/.bun/bin'
    log "Bun installed"
}

install_docker() {
    log "Installing Docker..."
    if command -v docker &>/dev/null; then warn "Already installed"; return; fi
    {
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
    } >> "$SETUP_LOG" 2>&1
    quiet "Installing Docker packages" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$NEW_USER"
    systemctl enable docker >> "$SETUP_LOG" 2>&1 && systemctl start docker >> "$SETUP_LOG" 2>&1
    log "Docker installed"
}

install_claude_code() {
    if ! curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh 2>> "$SETUP_LOG"; then
        warn "Claude Code download failed — install manually later"
        return 0
    fi
    quiet "Installing Claude Code" su - "$NEW_USER" -c "bash /tmp/claude-install.sh" || warn "Claude Code install failed — install manually later"
    rm -f /tmp/claude-install.sh
}

install_codex() {
    quiet "Installing Codex" su - "$NEW_USER" -c 'export PATH="$HOME/.npm-global/bin:$PATH" && npm install -g @openai/codex' || warn "Codex install failed — install manually later"
}

install_gemini_cli() {
    quiet "Installing Gemini CLI" su - "$NEW_USER" -c 'export PATH="$HOME/.npm-global/bin:$PATH" && npm install -g @google/gemini-cli' || warn "Gemini CLI install failed — install manually later"
}

install_opencode() {
    quiet "Installing OpenCode" su - "$NEW_USER" -c 'export PATH="$HOME/.npm-global/bin:$PATH" && npm install -g opencode-ai@latest' || warn "OpenCode install failed — install manually later"
}

install_tailscale() {
    log "Installing Tailscale..."
    if command -v tailscale &>/dev/null; then
        warn "Tailscale already installed"
    else
        if ! curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh 2>> "$SETUP_LOG"; then
            warn "Tailscale download failed — install manually: curl -fsSL https://tailscale.com/install.sh | sh"
            return 0
        fi
        quiet "Installing Tailscale" bash /tmp/tailscale-install.sh
        rm -f /tmp/tailscale-install.sh
    fi

    # tailscale up requires interactive auth — prints a URL the user must visit
    echo ""
    echo -e "  ${BOLD}Tailscale needs you to authenticate.${NC}"
    echo "  A login URL will appear below — open it in your browser to connect this server."
    echo ""
    tailscale up
    echo ""

    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$ts_ip" ]; then
        log "Tailscale connected! Private IP: $ts_ip"
    else
        warn "Tailscale installed but not connected. Run 'tailscale up' to connect later."
    fi
}

setup_agent_aliases() {
    log "Setting up coding agent aliases..."
    local alias_file="/home/$NEW_USER/.bash_aliases"

    cat > "$alias_file" << 'ALIASES'
# Coding agent aliases — added by dodo-vps setup

# Claude Code with auto-accept permissions (for autonomous agent loops)
alias cc='claude --dangerously-skip-permissions'

# Quick tmux session for background agents
alias agent='tmux new-session -d -s agent "claude --dangerously-skip-permissions" && tmux attach -t agent'

# Codex with full auto-approval
alias cx='codex --full-auto'

# Common server shortcuts
alias ports='ss -tlnp'
alias logs='journalctl -f'
alias disk='df -h'
alias mem='free -h'
ALIASES

    chown "$NEW_USER:$NEW_USER" "$alias_file"

    # Ensure .bash_aliases is sourced (Ubuntu default .bashrc usually does this,
    # but we add it just in case)
    if ! grep -q '\.bash_aliases' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        cat >> "/home/$NEW_USER/.bashrc" << 'EOF'

# Load custom aliases
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF
    fi

    log "Aliases configured (cc, cx, agent, ports, logs, disk, mem)"
}

setup_claude_config() {
    log "Setting up Claude Code statusline..."
    local claude_dir="/home/$NEW_USER/.claude"
    mkdir -p "$claude_dir"

    # Statusline script — two-line display:
    #   Line 1: repo name, git branch, diff stats, PRs, unpushed commits
    #   Line 2: model, context window %, tmux sessions, memory %, load average
    cat > "$claude_dir/statusline-command.sh" << 'STATUSLINE'
#!/bin/bash
# Claude Code statusline for Coding Agent VPS
#
# Line 1: Repo/code context (cool blues/cyans)
# Line 2: System health for agent management (color-coded metrics)
#
# Color thresholds:
#   Memory: green <70%, yellow 70-85%, red >85%
#   Load:   green <10, yellow 10-15, red >15
#   Context: green >50%, yellow 20-50%, red <20%

input=$(cat)

# Extract data from JSON
dir=$(echo "$input" | jq -r '.workspace.current_dir')
dir_name=$(basename "$dir")
model=$(echo "$input" | jq -r '.model.display_name // .model.id')

# Git info
if cd "$dir" 2>/dev/null; then
  branch=$(git -c core.useBuiltinFSMonitor=false branch --show-current 2>/dev/null)
  diff_stats=$(git -c core.useBuiltinFSMonitor=false diff --shortstat 2>/dev/null)

  if [ -n "$diff_stats" ]; then
    lines_added=$(echo "$diff_stats" | sed -n 's/.* \([0-9]*\) insertion.*/\1/p')
    lines_removed=$(echo "$diff_stats" | sed -n 's/.* \([0-9]*\) deletion.*/\1/p')
    [ -z "$lines_added" ] && lines_added=0
    [ -z "$lines_removed" ] && lines_removed=0
  else
    lines_added=0
    lines_removed=0
  fi

  # Unpushed commits count
  unpushed=$(git -c core.useBuiltinFSMonitor=false rev-list @{u}.. 2>/dev/null | wc -l)

  # PR count (only if gh is available)
  pr_count=0
  if command -v gh &>/dev/null; then
    pr_count=$(gh pr list --search "review-requested:@me state:open" --json number 2>/dev/null | jq '. | length' 2>/dev/null || echo 0)
  fi
else
  branch=''
  lines_added=0
  lines_removed=0
  unpushed=0
  pr_count=0
fi

# Context window calculation
usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$usage" != "null" ]; then
  current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
  size=$(echo "$input" | jq '.context_window.context_window_size')
  remaining=$((100 - (current * 100 / size)))

  if [ "$remaining" -gt 50 ]; then
    ctx_color='\033[92m'  # Green
  elif [ "$remaining" -gt 20 ]; then
    ctx_color='\033[93m'  # Yellow
  else
    ctx_color='\033[91m'  # Red
  fi
  ctx="${remaining}%"
else
  ctx=''
  ctx_color=''
fi

# Tmux session count
tmux_count=$(tmux list-sessions 2>/dev/null | wc -l)

# Memory usage percentage
mem_percent=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
if [ "$mem_percent" -lt 70 ]; then
  mem_color='\033[92m'  # Green
elif [ "$mem_percent" -lt 85 ]; then
  mem_color='\033[93m'  # Yellow
else
  mem_color='\033[91m'  # Red
fi

# Load average (1 minute)
load=$(awk '{printf "%.1f", $1}' /proc/loadavg)
load_int=$(awk '{printf "%.0f", $1}' /proc/loadavg)
if [ "$load_int" -lt 10 ]; then
  load_color='\033[92m'  # Green
elif [ "$load_int" -lt 15 ]; then
  load_color='\033[93m'  # Yellow
else
  load_color='\033[91m'  # Red
fi

# ============================================================
# LINE 1: Repo/Code (cool blues)
# ============================================================
line1=$(printf '\033[94m%s\033[0m' "$dir_name")

if [ -n "$branch" ]; then
  line1="$line1 $(printf '\033[2m│\033[0m \033[96m%s\033[0m' "$branch")"
fi

if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
  line1="$line1 $(printf '\033[2m│\033[0m \033[92m+%s\033[0m \033[91m-%s\033[0m' "$lines_added" "$lines_removed")"
fi

# PR and unpushed commits indicators
git_status=""
if [ "$pr_count" -gt 0 ]; then
  git_status="$(printf '\033[93m↓%s\033[0m' "$pr_count")"
fi
if [ "$unpushed" -gt 0 ]; then
  if [ -n "$git_status" ]; then
    git_status="$git_status $(printf '\033[96m↑%s\033[0m' "$unpushed")"
  else
    git_status="$(printf '\033[96m↑%s\033[0m' "$unpushed")"
  fi
fi
if [ -n "$git_status" ]; then
  line1="$line1 $(printf '\033[2m│\033[0m %b' "$git_status")"
fi

# ============================================================
# LINE 2: System Health (color-coded metrics)
# ============================================================
line2=$(printf '\033[37m%s\033[0m' "$model")

if [ -n "$ctx" ]; then
  line2="$line2 $(printf '\033[2m│\033[0m %b%s ctx\033[0m' "$ctx_color" "$ctx")"
fi

# Tmux sessions
line2="$line2 $(printf '\033[2m│\033[0m \033[95m%s sessions\033[0m' "$tmux_count")"

# Memory
line2="$line2 $(printf '\033[2m│\033[0m %b%s%% mem\033[0m' "$mem_color" "$mem_percent")"

# Load
line2="$line2 $(printf '\033[2m│\033[0m %b%s load\033[0m' "$load_color" "$load")"

# Output with blank line separator
printf '%b\n\n%b' "$line1" "$line2"
STATUSLINE

    chmod +x "$claude_dir/statusline-command.sh"

    # Minimal settings.json with statusline enabled
    local statusline_path="$claude_dir/statusline-command.sh"
    cat > "$claude_dir/settings.json" << SETTINGS
{
  "statusLine": {
    "type": "command",
    "command": "$statusline_path"
  }
}
SETTINGS

    chown -R "$NEW_USER:$NEW_USER" "$claude_dir"
    log "Claude Code statusline configured"
}

setup_tmp_cleanup() {
    log "Installing /tmp cleanup cron..."
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "/home/$NEW_USER/.local/bin"
    if [ -f "$SCRIPT_DIR/scripts/tmp-cleanup.sh" ]; then
        cp "$SCRIPT_DIR/scripts/tmp-cleanup.sh" "/home/$NEW_USER/.local/bin/tmp-cleanup"
    else
        curl -fsSL https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/scripts/tmp-cleanup.sh \
            -o "/home/$NEW_USER/.local/bin/tmp-cleanup"
    fi
    chmod +x "/home/$NEW_USER/.local/bin/tmp-cleanup"
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.local/bin/tmp-cleanup"
    add_user_path '$HOME/.local/bin'
    local EXISTING_CRON
    EXISTING_CRON=$(su - "$NEW_USER" -c 'crontab -l 2>/dev/null' || true)
    if ! echo "$EXISTING_CRON" | grep -q 'tmp-cleanup'; then
        (echo "$EXISTING_CRON"; echo "0 4 * * * /home/$NEW_USER/.local/bin/tmp-cleanup >/dev/null 2>&1") \
            | su - "$NEW_USER" -c 'crontab -'
    fi
    log "/tmp cleanup installed (daily at 4am)"
}

print_server_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Server Setup Complete!               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Installed:"
    echo "    - Node.js 22, Homebrew, Bun"
    [ "$INSTALL_DOCKER" = true ]      && echo "    - Docker"
    [ "$INSTALL_CLAUDE_CODE" = true ] && echo "    - Claude Code"
    [ "$INSTALL_CODEX" = true ]       && echo "    - Codex"
    [ "$INSTALL_GEMINI_CLI" = true ]  && echo "    - Gemini CLI"
    [ "$INSTALL_OPENCODE" = true ]    && echo "    - OpenCode"
    if [ "$INSTALL_TAILSCALE" = true ]; then
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null || true)
        if [ -n "$ts_ip" ]; then
            echo "    - Tailscale (IP: $ts_ip)"
        else
            echo "    - Tailscale (not connected — run 'tailscale up')"
        fi
    fi
    echo ""
    echo ""
    echo "  Aliases: cc (Claude auto), cx (Codex auto), agent (tmux session)"
    echo "  Security: firewall, fail2ban, SSH hardening, auto-updates"
    echo "  Maintenance: swap, /tmp cleanup cron"
    echo ""
    echo "  Full install log: $SETUP_LOG"
    echo ""
}

server_main() {
    check_root

    # Send noisy package manager output here instead of the terminal
    mkdir -p "$(dirname "$SETUP_LOG")"
    : > "$SETUP_LOG"

    log "Starting coding agent VPS setup..."
    log "Full install log: $SETUP_LOG"

    # System setup
    echo "  Preparing the server with the latest software and security patches."
    echo ""
    update_system
    create_user

    # Copy SSH keys to new user BEFORE hardening disables root login
    log "Setting up SSH access for $NEW_USER..."
    mkdir -p "/home/$NEW_USER/.ssh"
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
        chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    else
        warn "No /root/.ssh/authorized_keys found — add your SSH key manually:"
        warn "  ssh-copy-id $NEW_USER@<server-ip>"
    fi
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 700 "/home/$NEW_USER/.ssh"

    echo ""
    echo "  Locking down the server so only you can access it."
    echo ""
    setup_ssh_hardening
    setup_firewall
    setup_fail2ban
    setup_swap
    setup_auto_updates

    # Package managers & tools
    echo ""
    echo "  Installing coding agents and development tools."
    echo ""
    install_homebrew
    install_node

    if [ "$INSTALL_BUN" = true ]; then install_bun; fi
    if [ "$INSTALL_DOCKER" = true ]; then install_docker; fi
    if [ "$INSTALL_CLAUDE_CODE" = true ]; then install_claude_code; fi
    if [ "$INSTALL_CODEX" = true ]; then install_codex; fi
    if [ "$INSTALL_GEMINI_CLI" = true ]; then install_gemini_cli; fi
    if [ "$INSTALL_OPENCODE" = true ]; then install_opencode; fi

    # Claude Code config (statusline)
    if [ "$INSTALL_CLAUDE_CODE" = true ]; then setup_claude_config; fi

    # Aliases & cleanup
    setup_agent_aliases
    setup_tmp_cleanup

    # Tailscale (last because it requires interactive auth)
    if [ "$INSTALL_TAILSCALE" = true ]; then install_tailscale; fi

    # Make setup log readable by the service user
    chown "$NEW_USER:$NEW_USER" "$SETUP_LOG"

    print_server_summary
}

# =====================================================================
#  ENTRYPOINT
# =====================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --on-server) ON_SERVER=true; shift ;;
            --no-wizard) RUN_WIZARD=false; shift ;;
            --help|-h)
                echo "dodo-vps — One command to launch a coding-agent-ready VPS"
                echo ""
                echo "Usage:"
                echo "  /bin/bash -c \"\$(curl -fsSL .../setup.sh)\"   Run the wizard (from your laptop)"
                echo "  sudo ./setup.sh --on-server                Run server setup directly on a VPS"
                echo ""
                echo "Environment variables (headless mode):"
                echo "  HETZNER_TOKEN       Hetzner API token (required for remote provisioning)"
                echo "  SERVER_TYPE         cpx11/cpx21/cpx31/cpx41 (default: cpx21)"
                echo "  SERVER_LOCATION     ash/hil/nbg1/hel1 (default: ash)"
                echo "  NEW_USER            Username (default: ubuntu)"
                echo "  SSH_KEY_PATH        Path to SSH private key"
                echo "  INSTALL_DOCKER      true/false (default: true)"
                echo "  INSTALL_CLAUDE_CODE true/false (default: true)"
                echo "  INSTALL_CODEX       true/false (default: true)"
                echo "  INSTALL_GEMINI_CLI  true/false (default: true)"
                echo "  INSTALL_OPENCODE    true/false (default: true)"
                echo "  INSTALL_BUN         true/false (default: true)"
                echo "  INSTALL_TAILSCALE   true/false (default: false)"
                exit 0
                ;;
            *) error "Unknown option: $1" ;;
        esac
    done
}

ON_SERVER=false
parse_args "$@"

if [ "$ON_SERVER" = true ]; then
    server_main
else
    local_main
fi

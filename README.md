# dodo-vps

One command to launch a coding-agent-ready VPS.

Creates a hardened Hetzner server with Claude Code, Codex, Gemini CLI, and OpenCode pre-installed.

## Before You Start

You need two things. The wizard walks you through both.

### 1. Hetzner Cloud Account (required)

[Hetzner](https://console.hetzner.cloud/) hosts your server. Servers start at ~$6/month and you can delete anytime.

1. Create an account at [console.hetzner.cloud](https://console.hetzner.cloud/)
2. Create a project (or use the default one)
3. Go to **Security > API Tokens > Generate API Token**
4. Select **Read & Write** access and copy the token

### 2. API Keys for Your Coding Agents (after setup)

You don't need these during setup — the agents are installed either way. But you'll need at least one to start coding.

| Agent | Where to get the key | Env variable |
|-------|---------------------|--------------|
| Claude Code | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) | `ANTHROPIC_API_KEY` |
| Codex | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | `OPENAI_API_KEY` |
| Gemini CLI | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | `GEMINI_API_KEY` |
| OpenCode | Uses any of the above | Same as above |

### Optional

- **Tailscale account** — if you want private VPN access to your server. Free at [tailscale.com](https://tailscale.com). The setup wizard will ask.

## Quick Start

Run from your laptop:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/setup.sh)"
```

The wizard walks you through everything: server size, location, which agents to install. Takes about 10 minutes.

### Already have a VPS?

Run directly on an existing Ubuntu server:

```bash
curl -fsSL https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh --on-server
```

## What Gets Installed

### Coding Agents (all optional, all default to yes)

| Agent | Command | Provider |
|-------|---------|----------|
| Claude Code | `claude` | Anthropic |
| Codex | `codex` | OpenAI |
| Gemini CLI | `gemini` | Google |
| OpenCode | `opencode` | Open source |

### Development Tools

- **Node.js 22** with npm global prefix (no sudo needed for `npm install -g`)
- **Homebrew** (Linuxbrew) for dev tool management
- **Bun** runtime
- **Docker** (optional)

### Security & Maintenance

- SSH hardening (root login disabled, key-only auth)
- UFW firewall (SSH + HTTP/HTTPS only)
- Fail2ban (bans after 3 failed SSH attempts, 24h ban)
- Automatic security updates
- Swap (sized to match RAM, up to 16 GB)
- `/tmp` cleanup cron (daily at 4am)

## Server Costs (Hetzner)

| Size | Specs | Monthly Cost | Best For |
|------|-------|-------------|----------|
| Small | 2 GB / 2 CPU | ~$6/mo | Light usage, single agent |
| Medium | 4 GB / 3 CPU | ~$11/mo | Recommended for most users |
| Large | 8 GB / 4 CPU | ~$19/mo | Heavy usage, multiple agents |
| Extra Large | 16 GB / 8 CPU | ~$34/mo | Power user, concurrent workloads |

## Post-Setup

### Connect to your server

```bash
ssh -i ~/.ssh/dodo-vps_ed25519 ubuntu@<server-ip>
```

### Set your API keys

```bash
# Add to ~/.bashrc so they persist across sessions
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.bashrc
echo 'export OPENAI_API_KEY=sk-...' >> ~/.bashrc
echo 'export GEMINI_API_KEY=...' >> ~/.bashrc
source ~/.bashrc
```

See [Before You Start](#2-api-keys-for-your-coding-agents-after-setup) for where to get each key.

### Start coding

```bash
claude        # Claude Code
codex         # Codex
gemini        # Gemini CLI
opencode      # OpenCode
```

## Headless Mode

Skip the wizard with environment variables:

```bash
HETZNER_TOKEN=your-token \
SERVER_TYPE=cpx21 \
SERVER_LOCATION=ash \
NEW_USER=ubuntu \
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/setup.sh)"
```

All flags:

| Variable | Default | Options |
|----------|---------|---------|
| `HETZNER_TOKEN` | (required) | Your Hetzner API token |
| `SERVER_TYPE` | `cpx21` | `cpx11`, `cpx21`, `cpx31`, `cpx41` |
| `SERVER_LOCATION` | `ash` | `ash`, `hil`, `nbg1`, `hel1` |
| `NEW_USER` | `ubuntu` | Any valid Linux username |
| `SSH_KEY_PATH` | auto-generated | Path to existing SSH private key |
| `INSTALL_CLAUDE_CODE` | `true` | `true` / `false` |
| `INSTALL_CODEX` | `true` | `true` / `false` |
| `INSTALL_GEMINI_CLI` | `true` | `true` / `false` |
| `INSTALL_OPENCODE` | `true` | `true` / `false` |
| `INSTALL_DOCKER` | `true` | `true` / `false` |
| `INSTALL_BUN` | `true` | `true` / `false` |
| `INSTALL_TAILSCALE` | `false` | `true` / `false` |

## Tailscale

The setup wizard offers to install [Tailscale](https://tailscale.com) — a private VPN mesh that lets you access your server via a secure IP without exposing ports to the public internet.

During setup, you'll be prompted to authenticate by visiting a URL in your browser. Once connected, you can SSH via your server's Tailscale IP instead of its public IP.

To install Tailscale later on an existing server:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

## Troubleshooting

### Can't SSH after setup

Access via Hetzner console, then restore SSH config:

```bash
sudo rm /etc/ssh/sshd_config.d/99-dodo-vps-hardening.conf
sudo systemctl restart ssh
```

### npm install -g fails

The npm global prefix is set to `~/.npm-global`. Make sure it's in your PATH:

```bash
export PATH="$HOME/.npm-global/bin:$PATH"
```

### Homebrew not found

```bash
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

## Tested On

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Hetzner Cloud (CPX series)

## License

MIT

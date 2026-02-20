# Claude Code Podman Container

Run Claude Code, OpenCode, or Kiro CLI in isolated containers with root privileges, allowing them to install packages and modify the system freely without affecting your host.

## Container Flavors

| Tag | Base Image | What's Included |
|-----|-----------|-----------------|
| `minimal` (default) | `node:22-bookworm-slim` | Claude Code, tmux, git, curl, vim-tiny, openssh-client |
| `gastown` | `node:22-bookworm` | Everything in minimal + Go, Python 3, sqlite3, `gt` (GasTown CLI), `bd` (Beads CLI) |
| `opencode` | `debian:bookworm-slim` | OpenCode, tmux, git, curl, vim-tiny, openssh-client (no Node.js needed) |
| `opencode-gastown` | `debian:bookworm` | Everything in opencode + Go, Python 3, sqlite3, `gt` (GasTown CLI), `bd` (Beads CLI) |
| `kiro-minimal` | `amazonlinux:2023` | Kiro CLI, tmux, git, vim-minimal, openssh-clients, unzip |
| `kiro-gastown` | `amazonlinux:2023` | Everything in kiro-minimal + Go, Python 3, sqlite3, `gt` (GasTown CLI), `bd` (Beads CLI) |

## Quick Start

```bash
# Minimal container with a project directory
./run-llm-cli.sh ~/projects/myapp

# GasTown container with gt + bd
./run-llm-cli.sh -t gastown ~/projects/myapp

# OpenCode container
./run-llm-cli.sh -t opencode ~/projects/myapp

# Kiro CLI container
./run-llm-cli.sh -t kiro-minimal ~/projects/myapp

# Inside the container
claude       # for minimal/gastown
opencode     # for opencode/opencode-gastown
kiro-cli     # for kiro-minimal/kiro-gastown
```

## Prerequisites

**Container Runtime** (auto-detected in order of preference):
- Podman (recommended, rootless by default)
- Docker (requires explicit user mapping)
- machinectl/systemd-nspawn (not yet implemented)

**For Claude Code containers (minimal, gastown):**
- Claude Code authenticated on your host (run `claude` once to set up `~/.claude`)
- Or set `ANTHROPIC_API_KEY` environment variable

**For OpenCode containers (opencode, opencode-gastown):**
- Set one or more LLM API keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GEMINI_API_KEY`
- Or configure OpenCode on your host first (`~/.config/opencode/`)

**For Kiro CLI containers (kiro-minimal, kiro-gastown):**
- Kiro CLI configured on your host (run `kiro-cli` once to set up `~/.kiro/`)
- AWS credentials in `~/.aws/` (mounted read-only)
- Optional: Set `AWS_PROFILE` environment variable

## Usage

```
./run-llm-cli.sh [options] [directories...]

Options:
  -h, --help                    Show help message with credential instructions
  -t, --tag TAG                 Container flavor: minimal, gastown, opencode, opencode-gastown, kiro-minimal, kiro-gastown (default: minimal)
  -r, --container-runtime NAME  Specify container runtime: podman, docker (default: auto-detect)
  -g, --git                     Mount git credentials (~/.gitconfig and ~/.git-credentials)
  -s, --ssh PATHS               Mount specific SSH key files (comma-separated paths)
  -n, --no-build                Skip rebuilding the container image
  -p, --privileged              Run container in privileged mode (use with caution)

Arguments:
  directories...      Directories to mount into /workspace (space-separated)
```

## Examples

```bash
# Minimal container (default)
./run-llm-cli.sh ~/projects/myapp

# GasTown container
./run-llm-cli.sh -t gastown ~/projects/myapp

# With git HTTPS credentials
./run-llm-cli.sh -g ~/projects/myapp

# With specific SSH keys
./run-llm-cli.sh -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub ~/projects/myapp

# With SSH keys and config
./run-llm-cli.sh -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub,~/.ssh/config ~/projects/myapp

# Full setup: gastown + git + SSH + project
./run-llm-cli.sh -t gastown -g -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub,~/.ssh/config ~/projects/myapp

# OpenCode container
./run-llm-cli.sh -t opencode ~/projects/myapp

# OpenCode + GasTown
./run-llm-cli.sh -t opencode-gastown ~/projects/myapp

# Kiro CLI container
./run-llm-cli.sh -t kiro-minimal ~/projects/myapp

# Kiro + GasTown
./run-llm-cli.sh -t kiro-gastown ~/projects/myapp

# Specify container runtime explicitly
./run-llm-cli.sh -r docker ~/projects/myapp
./run-llm-cli.sh -r podman -t gastown ~/projects/myapp

# Multiple project directories
./run-llm-cli.sh ~/proj1 ~/proj2

# Skip rebuild if image already exists
./run-llm-cli.sh -n ~/projects/myapp
```

## Building Containers

Each flavor has its own build script in `containers/`:

```bash
# Build individually
./containers/minimal/build.sh
./containers/gastown/build.sh
./containers/opencode/build.sh
./containers/opencode-gastown/build.sh
./containers/kiro-minimal/build.sh
./containers/kiro-gastown/build.sh

# Use Docker instead of Podman for building
./containers/kiro-minimal/build.sh --use-docker

# Or let run-llm-cli.sh build automatically (default behavior)
./run-llm-cli.sh -t gastown ~/myproject
```

Images are tagged as `claude-code:<flavor>` (e.g. `claude-code:minimal`, `claude-code:gastown`, `claude-code:opencode`, `claude-code:kiro-minimal`).

## Git/GitHub Credentials

### Option 1: HTTPS with Git Credentials (`-g` flag)

```bash
# On your host, set up credential storage
git config --global credential.helper store

# Authenticate once (credentials get cached)
git push  # or any operation requiring auth

# Run container with -g flag
./run-claude-code.sh -g ~/myproject
```

This mounts `~/.gitconfig` and `~/.git-credentials` (read-only).

### Option 2: SSH Keys (`-s` flag)

```bash
# Specify exact files to mount (comma-separated)
./run-llm-cli.sh -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub ~/myproject

# Include config for host aliases
./run-llm-cli.sh -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub,~/.ssh/config ~/myproject
```

Files are mounted read-only to `/root/.ssh/` in the container. Use SSH URLs for git:

```bash
git clone git@github.com:user/repo.git
```

### Option 3: GitHub CLI (inside container)

```bash
# Inside the container, install and authenticate gh
apt-get update && apt-get install -y gh
gh auth login
```

## Container Details

- **Root access**: Container runs as root inside its namespace
- **Workspace**: Mounted directories appear in `/workspace/<dirname>`
- **Credentials**: `~/.claude` mounted to `/root/.claude` (Claude); `~/.config/opencode/` and `~/.local/share/opencode/` mounted for OpenCode; `~/.kiro` and `~/.aws` mounted for Kiro
- **Isolation**: Changes inside the container don't affect your host (except mounted directories)

## Inside the Container

```bash
# Start Claude Code (minimal/gastown)
claude

# Start OpenCode (opencode/opencode-gastown)
opencode

# Start Kiro CLI (kiro-minimal/kiro-gastown)
kiro-cli

# Use tmux for multiple terminals
tmux

# Your projects are in /workspace
cd /workspace/myapp

# Install additional tools as needed (you're root)
apt-get update && apt-get install -y <package>  # Debian-based
dnf install -y <package>                         # Amazon Linux

# GasTown container only: multi-agent orchestration
gt install ~/gt --git
gt mayor attach
```

## Security Notes

- Mounted directories are read-write; Claude can modify your project files
- Git/SSH credentials are mounted read-only
- The container has full root privileges inside its namespace
- Only mount credentials you're comfortable exposing to the container

## Troubleshooting

**"~/.claude not found" warning**

- Run `claude` on your host first to authenticate, or
- Set `ANTHROPIC_API_KEY` environment variable before running the script

**"~/.kiro not found" warning**

- Run `kiro-cli` on your host first to authenticate and configure

**No container runtime found**

- Install Podman (recommended) or Docker
- Script auto-detects available runtime: podman → docker → machinectl

**Permission denied on mounted files**

- The `:z` SELinux label is applied automatically
- If issues persist, check your Podman/SELinux configuration

**Container name conflict**

- The script uses `--rm` so containers are removed on exit
- If a container is stuck: `podman rm -f claude-code-session`

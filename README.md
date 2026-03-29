# Claude Code Podman Container

Run Claude Code in an isolated Podman container with root privileges, allowing it to install packages and modify the system freely without affecting your host.

## Container Flavors

| Tag | Base Image | What's Included |
|-----|-----------|-----------------|
| `minimal` (default) | `node:22-bookworm-slim` | Claude Code, tmux, git, curl, vim-tiny, openssh-client |
| `gastown` | `node:22-bookworm` | Everything in minimal + Go, Python 3, sqlite3, libicu-dev, `gt` (GasTown CLI), `bd` (Beads CLI) |
| `opencode` | `debian:bookworm-slim` | OpenCode, tmux, git, curl, vim-tiny, openssh-client (no Node.js needed) |
| `opencode-gastown` | `debian:bookworm` | Everything in opencode + Go, Python 3, sqlite3, libicu-dev, `gt` (GasTown CLI), `bd` (Beads CLI) |

## Quick Start

```bash
# Minimal container with a project directory
./run-llm-cli.sh ~/projects/myapp

# GasTown container with gt + bd
./run-llm-cli.sh -t gastown ~/projects/myapp

# OpenCode container
./run-llm-cli.sh -t opencode ~/projects/myapp

# OpenCode + GasTown
./run-llm-cli.sh -t opencode-gastown ~/projects/myapp

# Inside the container
claude     # for minimal/gastown
opencode   # for opencode/opencode-gastown
```

## Prerequisites

- Podman installed

**For Claude Code containers (minimal, gastown):**
- Claude Code authenticated on your host (run `claude` once to set up `~/.claude`)
- Or set `ANTHROPIC_API_KEY` environment variable

**For OpenCode containers (opencode, opencode-gastown):**
- Set one or more LLM API keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GEMINI_API_KEY`
- Or configure OpenCode on your host first (`~/.config/opencode/`)

## Usage

```
./run-llm-cli.sh [options] [directories...]

Options:
  -h, --help              Show help message with credential instructions
  -t, --tag TAG           Container flavor: minimal, gastown, opencode, opencode-gastown (default: minimal)
  -g, --git               Mount git credentials (~/.gitconfig and ~/.git-credentials)
  --git-config "author=NAME,email=EMAIL"
                          Set git author identity for commits inside the container
  -s, --ssh PATHS         Mount specific SSH key files (comma-separated paths)
  -n, --no-build          Skip rebuilding the container image
  -p, --privileged        Run container in privileged mode (use with caution)
  --gvisor                Run with gVisor (runsc) for stronger kernel-level isolation
  --fuse PATH             Mount PATH via fuse-overlayfs (version-tracked; repeatable)

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

# Use a dedicated LLM GitHub account for commits (limits permissions)
./run-llm-cli.sh --git-config "author=llm-bot,email=llm@example.com" ~/projects/myapp

# Mount host credentials but commit as a specific LLM identity
./run-llm-cli.sh -g --git-config "author=llm-bot,email=llm@example.com" ~/projects/myapp

# Full setup: gastown + git + SSH + project
./run-llm-cli.sh -t gastown -g -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub,~/.ssh/config ~/projects/myapp

# OpenCode container
./run-llm-cli.sh -t opencode ~/projects/myapp

# OpenCode + GasTown
./run-llm-cli.sh -t opencode-gastown ~/projects/myapp

# Multiple project directories
./run-llm-cli.sh ~/proj1 ~/proj2

# Skip rebuild if image already exists
./run-llm-cli.sh -n ~/projects/myapp

# Stronger kernel-level isolation with gVisor (requires gVisor installed)
./run-llm-cli.sh --gvisor ~/projects/myapp

# FUSE overlay mount with automatic version tracking
./run-llm-cli.sh --fuse ~/projects/myapp

# Combine: multiple fuse-mounted dirs
./run-llm-cli.sh --fuse ~/proj1 --fuse ~/proj2
```

## Building Containers

Each flavor has its own build script in `containers/`:

```bash
# Build individually
./containers/minimal/build.sh
./containers/gastown/build.sh
./containers/opencode/build.sh
./containers/opencode-gastown/build.sh

# Or let run-llm-cli.sh build automatically (default behavior)
./run-llm-cli.sh -t gastown ~/myproject
```

Images are tagged as `claude-code:<flavor>` (e.g. `claude-code:minimal`, `claude-code:gastown`, `claude-code:opencode`).

**Note:** The `bd` (Beads CLI) tool is built from source rather than via `go install ...@latest` because the beads module contains `replace` directives in its `go.mod`. The gastown containers also include `libicu-dev` since beads depends on ICU for regex support.

## Testing

**Container smoke tests** — builds all flavors, checks expected binaries are present, and cleans up:

```bash
# Test all flavors
./test/test-build.sh

# Test specific flavors
./test/test-build.sh minimal
./test/test-build.sh gastown opencode
```

Test images are tagged as `claude-code-test:<flavor>` and removed after the run.

**Git identity injection tests** — validates `--git-config` and `-g` flags without building containers:

```bash
./test/test-git-config.sh
```

## Git/GitHub Credentials

### Option 0: Custom Git Identity (`--git-config` flag)

Set an explicit author name and email for commits made inside the container:

```bash
./run-llm-cli.sh --git-config "author=llm-bot,email=llm@example.com" ~/myproject
```

This is useful when you want commits attributed to a dedicated LLM GitHub account with restricted permissions (e.g. no branch protection bypass). It injects `GIT_AUTHOR_*` and `GIT_COMMITTER_*` environment variables, which git always respects.

Can be combined with `-g` to mount host credentials for authentication while still committing as a specific identity — `--git-config` always takes precedence over the identity read from `~/.gitconfig`.

### Option 1: HTTPS with Git Credentials (`-g` flag)

```bash
# On your host, set up credential storage
git config --global credential.helper store

# Authenticate once (credentials get cached)
git push  # or any operation requiring auth

# Run container with -g flag
./run-llm-cli.sh -g ~/myproject
```

This mounts `~/.gitconfig` and `~/.git-credentials` (read-only), and also injects your host `user.name` / `user.email` as git identity env vars so commits work out of the box.

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
- **Credentials**: `~/.claude` mounted to `/root/.claude` (Claude); `~/.config/opencode/` and `~/.local/share/opencode/` mounted for OpenCode
- **Isolation**: Changes inside the container don't affect your host (except mounted directories)

## Inside the Container

```bash
# Start Claude Code (minimal/gastown)
claude

# Start OpenCode (opencode/opencode-gastown)
opencode

# Use tmux for multiple terminals
tmux

# Your projects are in /workspace
cd /workspace/myapp

# Install additional tools as needed (you're root)
apt-get update && apt-get install -y <package>

# GasTown container only: multi-agent orchestration
gt install ~/gt --git
gt mayor attach
```

## Security Notes

- Mounted directories are read-write; Claude can modify your project files
- Git/SSH credentials are mounted read-only
- The container has full root privileges inside its namespace
- Only mount credentials you're comfortable exposing to the container

## FUSE Overlay Versioning (`--fuse`)

`--fuse PATH` mounts a directory through a [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) layer. The container sees the original directory unchanged, but all writes land in an isolated `upper/` layer tracked by git in `~/.llm-safe-space/`.

**On container exit**, changes are automatically committed with a session timestamp. The original directory is never modified.

```bash
# First use: auto-initializes the version store, then mounts
./run-llm-cli.sh --fuse ~/myproject

# Multiple directories
./run-llm-cli.sh --fuse ~/proj1 --fuse ~/proj2
```

### Managing Versions (`fuse-versions.sh`)

```bash
# List all tracked directories
./fuse-versions.sh list

# Show version history for a directory
./fuse-versions.sh log ~/myproject

# See what changed (uncommitted or vs a revision)
./fuse-versions.sh diff ~/myproject
./fuse-versions.sh diff ~/myproject HEAD~2

# Show status and file listing of upper/ layer
./fuse-versions.sh status ~/myproject

# Manually commit with a message
./fuse-versions.sh commit ~/myproject -m "implemented feature X"

# Restore to a past version (must be unmounted)
./fuse-versions.sh restore ~/myproject abc1234

# Discard uncommitted changes (must be unmounted)
./fuse-versions.sh clean ~/myproject
```

**Prerequisites**: `fuse-overlayfs` must be installed on the host.

```bash
# Debian/Ubuntu
sudo apt-get install fuse-overlayfs

# Fedora/RHEL
sudo dnf install fuse-overlayfs
```

### gVisor (`--gvisor`)

[gVisor](https://gvisor.dev) adds an extra layer of isolation by intercepting syscalls in user space rather than passing them directly to the host kernel. This limits the blast radius of a container escape.

```bash
# Requires gVisor installed on the host (runsc in PATH)
./run-llm-cli.sh --gvisor ~/myproject
```

Install gVisor: https://gvisor.dev/docs/user_guide/install/

Note: gVisor has a performance overhead and some syscalls may not be supported. Incompatible with `--privileged`.

## Troubleshooting

**"~/.claude not found" warning**

- Run `claude` on your host first to authenticate, or
- Set `ANTHROPIC_API_KEY` environment variable before running the script

**Permission denied on mounted files**

- The `:z` SELinux label is applied automatically
- If issues persist, check your Podman/SELinux configuration

**Container name conflict**

- The script uses `--rm` so containers are removed on exit
- If a container is stuck: `podman rm -f claude-code-session`

# Implementation Plan - Add Kiro CLI and Docker Support

## Problem Statement

Add Kiro CLI support and Docker runtime to the llm_safe_space project. Docker implementation must run containers as non-root users (matching host UID/GID) to prevent Kiro from having privileged host access, addressing Docker's security limitations compared to Podman's rootless mode. The solution should support Amazon Linux environments where Docker is standard but Podman may not be available.

## Requirements

1. **Docker for Amazon Linux compatibility** - Podman not widely available on Amazon Linux, Docker is standard
2. **Full workspace write access** - Kiro can modify mounted project files (matches current behavior)
3. **Hybrid containers** - Add Kiro to existing containers alongside Claude/OpenCode, create new kiro-specific variants
4. **Match host user permissions** - Use host UID/GID in Docker containers so files written have correct ownership
5. **Mount ~/.kiro/ config** - Similar to ~/.claude mounting pattern
6. **Auto-detect runtime** - Favor Podman if both available, fallback to Docker, then machinectl/systemd-nspawn, finally direct execution
7. **Tag-based tool defaults** - Container tag determines which CLI tool runs by default (e.g., kiro-gastown defaults to Kiro)
8. **Docker-specific UID/GID handling** - Use `--user` flag for Docker only (Podman handles rootless differently)
9. **Kiro CLI from AWS** - Download pre-built binaries from AWS S3 (architecture-specific)
10. **Amazon Linux 2023 base** - Use AL2023 as base image for Kiro containers
11. **GasTown PR #1278** - For kiro-gastown, use xcawolfe-amzn/gastown@kiro-cli branch

## Background

- **PR #1278 context**: Adds kiro-cli integration to GasTown with command `kiro-cli chat --trust-all-tools`
- **Kiro CLI distribution**: Pre-built binaries from `https://desktop-release.q.us-east-1.amazonaws.com/latest/kirocli-{arch}-linux.zip`
- **Docker UID/GID mapping**: Docker `--user $(id -u):$(id -g)` ensures files created in volumes match host user ownership
- **Podman vs Docker**: Podman runs rootless by default; Docker requires explicit `--user` flag for non-root execution
- **systemd-nspawn**: Lightweight container alternative using Linux namespaces, suitable as fallback

## Proposed Solution

Create new Kiro-specific container variants (kiro-minimal, kiro-gastown) based on Amazon Linux 2023 with non-root user setup. Enhance the launcher script to auto-detect runtime (Podman → Docker → systemd-nspawn → direct), apply Docker-specific `--user` flags, and mount `~/.kiro/` config. Install Kiro CLI from AWS-hosted binaries.

## Task Breakdown

### Task 1: Create kiro-minimal container with non-root user (Amazon Linux 2023 base)

**STATUS: IN PROGRESS - Fixing RPM Installation Issues**

**Current Issue**: Same RPM chown errors as kiro-gastown with tmux, git, and other packages

**Solution Applied**: Add `--setopt=tsflags=nodocs` to dnf install command to skip documentation and reduce file conflicts

**Previous Success**: Built successfully with Docker initially, but needs nodocs flag for reliability

**Key Learnings**:
- Amazon Linux 2023 base image has `curl-minimal` pre-installed; installing `curl` causes conflicts
- Kiro CLI zip extracts to `kirocli/bin/kiro-cli` not `kiro-cli` directly
- Docker requires explicit `-f Containerfile` flag; Podman auto-detects it
- Build script supports `--use-docker` flag for runtime selection
- RPM chown errors common in AL2023 containers, nodocs flag helps

**Deliverables**:
- ✅ `containers/kiro-minimal/Containerfile` - AL2023 base with tmux, git, unzip, kiro-cli
- ✅ `containers/kiro-minimal/build.sh` - Build script with --use-docker flag
- ✅ Non-root user `kirouser` (UID 1000, GID 1000)
- ⏳ Testing build with nodocs flag

**Next Step**: Rebuild and verify kiro-cli v1.26.2 works

- Create `containers/kiro-minimal/Containerfile` based on `amazonlinux:2023`

- Create `containers/kiro-minimal/Containerfile` based on `amazonlinux:2023`
- Install essential tools via dnf: tmux, git, curl, vim-minimal, openssh-clients, ca-certificates, unzip
- Detect architecture and download appropriate Kiro CLI binary:
  - x86_64: `https://desktop-release.q.us-east-1.amazonaws.com/latest/kirocli-x86_64-linux.zip`
  - aarch64: `https://desktop-release.q.us-east-1.amazonaws.com/latest/kirocli-aarch64-linux.zip`
- Extract kiro-cli binary to `/usr/local/bin/` and make executable
- Create non-root user `kirouser` with UID 1000, GID 1000 (will be overridden at runtime)
- Set working directory to `/workspace` with appropriate permissions
- Create `containers/kiro-minimal/build.sh` script

**Test**: Build image successfully for both architectures, verify kiro-cli binary exists and is executable, confirm non-root user created

**Demo**: `podman build -t claude-code:kiro-minimal containers/kiro-minimal/` completes successfully

### Task 2: Create kiro-gastown container with GasTown tools (Amazon Linux 2023 base)

**STATUS: BLOCKED - RPM Installation Failures**

**Current Blocker**: Amazon Linux 2023 RPM package installation failures during container build:
- `libutempter-1.2.1-4.amzn2023.0.2.x86_64` - chown failed: Directory not empty
- `util-linux-2.37.4-1.amzn2023.0.4.x86_64` - chown failed: No data available  
- `openssh-8.7p1-8.amzn2023.0.15.x86_64` - chown failed: No data available

**Root Cause**: RPM chown failures during package installation in AL2023 containers. The errors occur with packages that have setuid/setgid binaries or special file permissions (libutempter, util-linux, openssh).

**Solution Applied**: 
1. Use `vim-minimal` instead of `vim` (lighter, fewer permission issues)
2. Add `--setopt=tsflags=nodocs` to skip documentation installation (reduces file conflicts)
3. Remove `python3` from install list (already in base image)

**Previous Blocker (Resolved)**: GasTown compilation errors - main branch has missing fields in `AgentPresetInfo` struct

**Files Created**:
- ✅ `containers/kiro-gastown/Containerfile` - Ready but blocked by RPM issues
- ✅ `containers/kiro-gastown/build.sh` - Build script ready

**Next Steps**:
1. Try dnf install with `--setopt=tsflags=nodocs --nobest --skip-broken`
2. If still failing, consider Debian base for kiro-gastown (Ubuntu 24.04 or Debian bookworm)
3. After successful build, verify gt, bd, and kiro-cli binaries are present

### Task 3: Add runtime detection logic to launcher script

**STATUS: COMPLETE**

**Solution**: Added runtime detection with fallback chain (podman → docker → machinectl → direct) and kiro config mounting support.

**Key Learnings**:
- Runtime detection happens early after argument parsing
- PODMAN_ARGS renamed to RUNTIME_ARGS for runtime-agnostic operation
- Kiro containers mount ~/.kiro config and ~/.aws credentials (read-only)
- machinectl and direct execution marked as not yet implemented with clear error messages

**Deliverables**:
- ✅ `detect_runtime()` function - Checks for podman, docker, machinectl, direct in order
- ✅ `check_kiro_config()` function - Verifies ~/.kiro exists or creates it with warning
- ✅ `is_kiro_container()` function - Determines if tag starts with "kiro"
- ✅ Runtime-agnostic build command - Uses detected runtime for image building
- ✅ Runtime-agnostic run command - Uses detected runtime with error handling
- ✅ Kiro config mounting - Mounts ~/.kiro and ~/.aws for kiro-* containers

**Test**: Runtime detection correctly identifies podman, kiro config check works, syntax validation passes

**Demo**: `bash -n run-llm-cli.sh` passes, runtime detection outputs "Detected runtime: podman"

### Task 4: Add Docker-specific UID/GID handling

- Add logic to detect if runtime is Docker (not Podman)

**Demo**: Script prints detected runtime and proceeds with appropriate commands

### Task 4: Implement Docker-specific user mapping

- Add `get_user_args()` function that returns `--user $(id -u):$(id -g)` for Docker, empty for Podman
- Modify volume mount logic to handle user-owned workspace directories
- Add `KIRO_MOUNT_ARGS` variable for mounting `~/.kiro/:/home/kirouser/.kiro:ro,z`
- Update container run command construction to include user args conditionally

**Test**: Docker containers run as host user, files created have correct ownership

**Demo**: Create file in mounted workspace from Docker container, verify host user owns it

### Task 5: Add systemd-nspawn fallback implementation

- Create `run_with_nspawn()` function that uses `systemd-nspawn` with minimal Debian bootstrap
- Function creates temporary container root in `/tmp/kiro-nspawn-XXXXX`
- Use `debootstrap` to create minimal Debian environment if not exists
- Mount workspace directories with `--bind` flag
- Install kiro-cli inside nspawn container on first run

**Test**: systemd-nspawn successfully creates container and runs kiro-cli

**Demo**: On system without Docker/Podman, script falls back to systemd-nspawn successfully

### Task 6: Add direct execution fallback

- Create `run_direct()` function that checks for kiro-cli in PATH
- If not found, provide installation instructions
- Execute `kiro-cli chat --trust-all-tools` directly with workspace as CWD
- Add warning message about lack of isolation

**Test**: Direct execution works when kiro-cli installed on host

**Demo**: Script runs kiro-cli directly when no containerization available

### Task 7: Update launcher script flags and help

- Add `--use-kiro` and `--use-claude` flags to override default tool selection
- Update help text to document new kiro-minimal and kiro-gastown tags
- Add Docker-specific notes about non-root execution
- Update examples section with kiro container usage
- Add credential mounting section for `~/.kiro/`

**Test**: Help text displays correctly, flags parse properly

**Demo**: `./run-llm-cli.sh --help` shows complete updated documentation

### Task 8: Wire everything together and update README

- Integrate all functions into main script flow
- Add container name generation for kiro variants
- Update README.md with new container flavors table (add kiro-minimal, kiro-gastown rows)
- Add Docker vs Podman security notes section
- Document systemd-nspawn and direct execution fallbacks
- Add Kiro CLI authentication instructions
- Update examples with kiro-specific usage patterns

**Test**: End-to-end test with each runtime (Podman, Docker, nspawn, direct)

**Demo**: Complete workflow - build kiro-gastown, run with Docker using host UID, create files with correct permissions, kiro-cli starts successfully

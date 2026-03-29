#!/bin/bash
#
# Run Claude Code in a Podman container with optional directory mounts
#
# Usage: ./run-claude-code.sh [options] [directories...]
#
# Options:
#   -h, --help          Show this help message
#   -t, --tag TAG       Container flavor: minimal, gastown, opencode, opencode-gastown (default: minimal)
#   -g, --git           Mount git credentials (~/.gitconfig and ~/.git-credentials)
#   --git-config CFG    Set git author identity (e.g. "author=llm-bot,email=llm@example.com")
#   --git-token TOKEN   HTTPS token for git auth; TOKEN may be plain or "user:token"
#   --git-host HOST     Git host for --git-token (default: github.com)
#   -s, --ssh PATHS     Mount specific SSH key files (comma-separated paths)
#   -n, --no-build      Skip building the container image
#   -p, --privileged    Run container in privileged mode (use with caution)
#   --gvisor            Run container with gVisor (runsc runtime) for stronger isolation
#   --fuse PATH         Mount PATH via fuse-overlayfs overlay (version-tracked; repeatable)
#
# Arguments:
#   directories...      Directories to mount into /workspace (space-separated)
#
# Examples:
#   ./run-claude-code.sh ~/projects/myapp              # Minimal container
#   ./run-claude-code.sh -t gastown ~/projects/myapp   # GasTown container (gt + bd)
#   ./run-claude-code.sh -t opencode ~/projects/myapp  # OpenCode container
#   ./run-claude-code.sh -t opencode-gastown ~/proj    # OpenCode + GasTown
#   ./run-claude-code.sh -g ~/projects/myapp           # Mount with git credentials
#   ./run-claude-code.sh --git-config "author=llm-bot,email=llm@example.com" ~/myapp
#   ./run-claude-code.sh --git-token ghp_mytoken ~/myapp
#   ./run-claude-code.sh --git-token myuser:mytoken --git-host gitlab.com ~/myapp
#   ./run-claude-code.sh -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub ~/myapp
#   ./run-claude-code.sh -g -s ~/.ssh/github_key,~/.ssh/github_key.pub,~/.ssh/config ~/proj
#   ./run-claude-code.sh --gvisor ~/myapp                    # gVisor kernel-level isolation
#   ./run-claude-code.sh --fuse ~/myapp                      # FUSE overlay with version tracking
#

set -e

CONTAINER_TAG="minimal"
CONTAINER_NAME="claude-code-$(date +%s)-$$"

# Temp files created during setup; cleaned up on exit
TMPFILES=()
FUSE_DIRS=()
MOUNTED_FUSE_DIRS=()

cleanup() {
    # Remove temp credential files
    [ ${#TMPFILES[@]} -gt 0 ] && rm -f "${TMPFILES[@]}"

    # Auto-commit and unmount FUSE overlays (guarded: SCRIPT_DIR may not be set on early exit)
    if [ -n "${SCRIPT_DIR:-}" ] && [ ${#MOUNTED_FUSE_DIRS[@]} -gt 0 ]; then
        local fuse_script="$SCRIPT_DIR/fuse-versions.sh"
        if [ -x "$fuse_script" ]; then
            for fdir in "${MOUNTED_FUSE_DIRS[@]}"; do
                local session_ts
                session_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
                echo "FUSE: committing changes for $fdir ..."
                "$fuse_script" commit "$fdir" -m "auto-commit: session ended $session_ts" || true
                echo "FUSE: unmounting $fdir ..."
                "$fuse_script" umount "$fdir" || true
            done
        fi
    fi
}
trap cleanup EXIT

# Parse options
MOUNT_GIT=false
GIT_CONFIG_STR=""
GIT_TOKEN=""
GIT_TOKEN_HOST="github.com"
SSH_KEYS=()
SKIP_BUILD=false
PRIVILEGED=false
USE_GVISOR=false
DIRS=()

show_help() {
    head -36 "$0" | tail -35 | sed 's/^# \?//'
    echo ""
    echo "=========================================="
    echo "GIT/GITHUB CREDENTIALS INSTRUCTIONS"
    echo "=========================================="
    echo ""
    echo "Option 0: Custom Git Identity (--git-config flag)"
    echo "  Use a specific author name and email for commits inside the container:"
    echo "    --git-config \"author=llm-bot,email=llm@example.com\""
    echo "  Useful for LLM-specific GitHub accounts with restricted permissions."
    echo "  Can be combined with -g (--git-config identity takes precedence)."
    echo ""
    echo "Option 1: HTTPS with Git Credentials (-g flag)"
    echo "  1. Configure git credential storage on your host:"
    echo "     git config --global credential.helper store"
    echo "  2. Run any git operation that requires auth to cache credentials"
    echo "  3. Run this script with -g flag to mount ~/.gitconfig and ~/.git-credentials"
    echo ""
    echo "Option 1b: HTTPS Token (--git-token flag)"
    echo "  Pass a Personal Access Token (PAT) or similar HTTPS credential directly:"
    echo "    --git-token ghp_yourtoken                  # GitHub, user defaults to x-access-token"
    echo "    --git-token myuser:ghp_yourtoken           # explicit username"
    echo "    --git-token mytoken --git-host gitlab.com  # non-GitHub provider"
    echo "  A temporary credentials file is created for the session and deleted on exit."
    echo "  Can be combined with -g (token file takes precedence for that host)."
    echo ""
    echo "Option 2: SSH Keys (-s flag with specific paths)"
    echo "  1. Specify exact SSH files to mount (comma-separated):"
    echo "     -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub"
    echo "  2. Include ~/.ssh/config if needed for host aliases:"
    echo "     -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub,~/.ssh/config"
    echo "  3. Use SSH URLs for git (git@github.com:user/repo.git)"
    echo "  4. Files are mounted read-only to /root/.ssh/"
    echo ""
    echo "Option 3: GitHub CLI (gh)"
    echo "  The container includes git. You can install gh inside and run:"
    echo "     gh auth login"
    echo ""
    echo "Security Note:"
    echo "  Mounting credentials gives the container full access to your git/GitHub."
    echo "  Only use with trusted code and understand the implications."
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -t|--tag)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: -t/--tag requires a tag name (minimal, gastown, opencode, opencode-gastown)"
                exit 1
            fi
            CONTAINER_TAG="$2"
            shift 2
            ;;
        -g|--git)
            MOUNT_GIT=true
            shift
            ;;
        --git-config)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: --git-config requires a value (e.g. \"author=llm-bot,email=llm@example.com\")"
                exit 1
            fi
            GIT_CONFIG_STR="$2"
            shift 2
            ;;
        --git-token)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: --git-token requires a token (e.g. ghp_mytoken or myuser:mytoken)"
                exit 1
            fi
            GIT_TOKEN="$2"
            shift 2
            ;;
        --git-host)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: --git-host requires a hostname (e.g. gitlab.com)"
                exit 1
            fi
            GIT_TOKEN_HOST="$2"
            shift 2
            ;;
        -s|--ssh)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: -s/--ssh requires comma-separated paths"
                echo "Example: -s ~/.ssh/id_ed25519,~/.ssh/id_ed25519.pub"
                exit 1
            fi
            IFS=',' read -ra SSH_KEYS <<< "$2"
            shift 2
            ;;
        -n|--no-build)
            SKIP_BUILD=true
            shift
            ;;
        -p|--privileged)
            PRIVILEGED=true
            shift
            ;;
        --gvisor)
            USE_GVISOR=true
            shift
            ;;
        --fuse)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: --fuse requires a directory path"
                exit 1
            fi
            FUSE_DIRS+=("$2")
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
        *)
            DIRS+=("$1")
            shift
            ;;
    esac
done

# Validate fuse-overlayfs is installed when --fuse is used
if [ ${#FUSE_DIRS[@]} -gt 0 ]; then
    if ! command -v fuse-overlayfs &>/dev/null; then
        echo "Error: --fuse requires fuse-overlayfs (not found in PATH)"
        echo "Install: https://github.com/containers/fuse-overlayfs"
        echo "  Debian/Ubuntu: sudo apt-get install fuse-overlayfs"
        echo "  Fedora/RHEL:   sudo dnf install fuse-overlayfs"
        exit 1
    fi
fi

# Validate gVisor is installed if requested
if [ "$USE_GVISOR" = true ]; then
    if ! command -v runsc &>/dev/null; then
        echo "Error: --gvisor requires gVisor to be installed (runsc not found in PATH)"
        echo "Install gVisor: https://gvisor.dev/docs/user_guide/install/"
        exit 1
    fi
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Init, mount, and collect FUSE overlay volumes
FUSE_VOLUME_ARGS=()
if [ ${#FUSE_DIRS[@]} -gt 0 ]; then
    FUSE_SCRIPT="$SCRIPT_DIR/fuse-versions.sh"
    if [ ! -x "$FUSE_SCRIPT" ]; then
        echo "Error: fuse-versions.sh not found or not executable at $FUSE_SCRIPT"
        exit 1
    fi

    for fdir in "${FUSE_DIRS[@]}"; do
        abs_fdir="$(cd "$fdir" 2>/dev/null && pwd)" || {
            echo "Error: FUSE directory not found: $fdir"
            exit 1
        }

        # Auto-init if this directory hasn't been tracked before
        fuse_store="$HOME/.llm-safe-space/$(echo "$abs_fdir" | sha256sum | cut -c1-16)"
        if [ ! -d "$fuse_store/.git" ]; then
            echo "FUSE: initializing version store for $abs_fdir ..."
            "$FUSE_SCRIPT" init "$abs_fdir"
        fi

        # Mount (idempotent — skips if already mounted)
        "$FUSE_SCRIPT" mount "$abs_fdir"

        # Track for auto-commit + umount on container exit
        MOUNTED_FUSE_DIRS+=("$abs_fdir")

        # Mount the overlay's merged view into the container
        merged_path="$("$FUSE_SCRIPT" merged "$abs_fdir")"
        dir_name="$(basename "$abs_fdir")"
        echo "FUSE overlay: $merged_path -> /workspace/$dir_name"
        FUSE_VOLUME_ARGS+=("-v" "$merged_path:/workspace/$dir_name:z")
    done
fi

# Resolve container directory and image name from tag
CONTAINER_DIR="$SCRIPT_DIR/containers/$CONTAINER_TAG"
IMAGE_NAME="claude-code:$CONTAINER_TAG"

if [ ! -d "$CONTAINER_DIR" ]; then
    echo "Error: unknown container tag '$CONTAINER_TAG'"
    echo "Available tags:"
    for d in "$SCRIPT_DIR"/containers/*/; do
        [ -d "$d" ] && echo "  $(basename "$d")"
    done
    exit 1
fi

# Build the image if needed
if [ "$SKIP_BUILD" = false ]; then
    echo "Building $IMAGE_NAME ..."
    podman build -t "$IMAGE_NAME" "$CONTAINER_DIR"
fi

# Start building the podman run command
PODMAN_ARGS=(
    "run"
    "--rm"
    "-it"
    "--name" "$CONTAINER_NAME"
    "--hostname" "claude-code"
    # Run as root inside the container
    "--user" "root"
    # Let Claude Code know it's running in a sandbox/dev container
    "-e" "IS_SANDBOX=1"
)

# Add privileged mode if requested
if [ "$PRIVILEGED" = true ]; then
    echo "Warning: Running in privileged mode - container has elevated host access"
    PODMAN_ARGS+=("--privileged")
fi

# Use gVisor runtime if requested
if [ "$USE_GVISOR" = true ]; then
    echo "Using gVisor runtime (runsc) for enhanced isolation"
    PODMAN_ARGS+=("--runtime" "runsc")
fi

# Mount credentials based on container type
if [[ "$CONTAINER_TAG" == opencode* ]]; then
    # OpenCode stores config in ~/.config/opencode and data in ~/.local/share/opencode
    OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
    OPENCODE_DATA_DIR="$HOME/.local/share/opencode"

    if [ -d "$OPENCODE_CONFIG_DIR" ]; then
        echo "Mounting OpenCode config from $OPENCODE_CONFIG_DIR"
    else
        echo "Creating OpenCode config directory..."
        mkdir -p "$OPENCODE_CONFIG_DIR"
    fi
    PODMAN_ARGS+=("-v" "$OPENCODE_CONFIG_DIR:/root/.config/opencode:z")

    if [ -d "$OPENCODE_DATA_DIR" ]; then
        echo "Mounting OpenCode data from $OPENCODE_DATA_DIR"
    else
        echo "Creating OpenCode data directory..."
        mkdir -p "$OPENCODE_DATA_DIR"
    fi
    PODMAN_ARGS+=("-v" "$OPENCODE_DATA_DIR:/root/.local/share/opencode:z")

    # Pass common LLM API keys if set
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        echo "Passing ANTHROPIC_API_KEY environment variable"
        PODMAN_ARGS+=("-e" "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    fi
    if [ -n "$OPENAI_API_KEY" ]; then
        echo "Passing OPENAI_API_KEY environment variable"
        PODMAN_ARGS+=("-e" "OPENAI_API_KEY=$OPENAI_API_KEY")
    fi
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "Passing GEMINI_API_KEY environment variable"
        PODMAN_ARGS+=("-e" "GEMINI_API_KEY=$GEMINI_API_KEY")
    fi
else
    # Claude Code stores config in ~/.claude
    CLAUDE_CONFIG_DIR="$HOME/.claude"
    if [ -d "$CLAUDE_CONFIG_DIR" ]; then
        echo "Mounting Anthropic credentials from $CLAUDE_CONFIG_DIR"
        PODMAN_ARGS+=("-v" "$CLAUDE_CONFIG_DIR:/root/.claude:z")
    else
        echo "Warning: $CLAUDE_CONFIG_DIR not found. You may need to run 'claude' to authenticate first."
        echo "Creating directory for credentials..."
        mkdir -p "$CLAUDE_CONFIG_DIR"
        PODMAN_ARGS+=("-v" "$CLAUDE_CONFIG_DIR:/root/.claude:z")
    fi

    # Also check for ANTHROPIC_API_KEY environment variable
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        echo "Passing ANTHROPIC_API_KEY environment variable"
        PODMAN_ARGS+=("-e" "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    fi
fi

# Mount git credentials if requested
if [ "$MOUNT_GIT" = true ]; then
    if [ -f "$HOME/.gitconfig" ]; then
        echo "Mounting git config"
        PODMAN_ARGS+=("-v" "$HOME/.gitconfig:/root/.gitconfig:ro,z")
    else
        echo "Warning: ~/.gitconfig not found"
    fi

    if [ -f "$HOME/.git-credentials" ]; then
        echo "Mounting git credentials"
        PODMAN_ARGS+=("-v" "$HOME/.git-credentials:/root/.git-credentials:ro,z")
    else
        echo "Warning: ~/.git-credentials not found (run 'git config --global credential.helper store' and authenticate once)"
    fi
fi

# Set up HTTPS token credentials if requested
if [ -n "$GIT_TOKEN" ]; then
    # Support "user:token" format; default username for plain tokens is x-access-token
    if [[ "$GIT_TOKEN" == *:* ]]; then
        GIT_TOKEN_USER="${GIT_TOKEN%%:*}"
        GIT_TOKEN_SECRET="${GIT_TOKEN#*:}"
    else
        GIT_TOKEN_USER="x-access-token"
        GIT_TOKEN_SECRET="$GIT_TOKEN"
    fi

    GIT_CREDS_TMP="$(mktemp)"
    TMPFILES+=("$GIT_CREDS_TMP")
    chmod 600 "$GIT_CREDS_TMP"
    printf 'https://%s:%s@%s\n' "$GIT_TOKEN_USER" "$GIT_TOKEN_SECRET" "$GIT_TOKEN_HOST" > "$GIT_CREDS_TMP"
    echo "Git HTTPS token configured for $GIT_TOKEN_HOST (user: $GIT_TOKEN_USER)"
    PODMAN_ARGS+=("-v" "$GIT_CREDS_TMP:/root/.git-credentials:ro,z")

    # If -g wasn't used we also need a gitconfig that enables the credential store helper
    if [ "$MOUNT_GIT" = false ]; then
        GIT_CFG_TMP="$(mktemp)"
        TMPFILES+=("$GIT_CFG_TMP")
        printf '[credential]\n\thelper = store\n' > "$GIT_CFG_TMP"
        PODMAN_ARGS+=("-v" "$GIT_CFG_TMP:/root/.gitconfig:ro,z")
    fi
fi

# Set git author identity. --git-config takes precedence over -g (host gitconfig).
GIT_AUTHOR_NAME_VAL=""
GIT_AUTHOR_EMAIL_VAL=""

if [ -n "$GIT_CONFIG_STR" ]; then
    # Parse "author=X,email=Y" (order-independent)
    for pair in ${GIT_CONFIG_STR//,/ }; do
        key="${pair%%=*}"
        val="${pair#*=}"
        case "$key" in
            author) GIT_AUTHOR_NAME_VAL="$val" ;;
            email)  GIT_AUTHOR_EMAIL_VAL="$val" ;;
            *) echo "Warning: unknown --git-config key '$key' (expected author, email)" ;;
        esac
    done
elif [ "$MOUNT_GIT" = true ]; then
    # Fall back to host git identity
    GIT_AUTHOR_NAME_VAL="$(git config --global user.name 2>/dev/null || true)"
    GIT_AUTHOR_EMAIL_VAL="$(git config --global user.email 2>/dev/null || true)"
fi

if [ -n "$GIT_AUTHOR_NAME_VAL" ]; then
    echo "Git author: $GIT_AUTHOR_NAME_VAL <$GIT_AUTHOR_EMAIL_VAL>"
    PODMAN_ARGS+=("-e" "GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME_VAL")
    PODMAN_ARGS+=("-e" "GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME_VAL")
fi
if [ -n "$GIT_AUTHOR_EMAIL_VAL" ]; then
    PODMAN_ARGS+=("-e" "GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL_VAL")
    PODMAN_ARGS+=("-e" "GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL_VAL")
fi
if { [ "$MOUNT_GIT" = true ] || [ -n "$GIT_CONFIG_STR" ]; } && \
   { [ -z "$GIT_AUTHOR_NAME_VAL" ] || [ -z "$GIT_AUTHOR_EMAIL_VAL" ]; }; then
    echo "Warning: git author name or email not set — commits inside container may fail"
fi

# Mount SSH keys if specified
if [ ${#SSH_KEYS[@]} -gt 0 ]; then
    echo "Mounting SSH keys..."
    for key_path in "${SSH_KEYS[@]}"; do
        # Expand tilde and resolve path
        expanded_path="${key_path/#\~/$HOME}"
        if [ -f "$expanded_path" ]; then
            key_name="$(basename "$expanded_path")"
            echo "  Mounting $expanded_path -> /root/.ssh/$key_name"
            PODMAN_ARGS+=("-v" "$expanded_path:/root/.ssh/$key_name:ro,z")
        else
            echo "Warning: SSH key not found: $key_path"
        fi
    done
fi

# Mount requested directories
if [ ${#DIRS[@]} -gt 0 ]; then
    for dir in "${DIRS[@]}"; do
        # Expand to absolute path
        abs_dir="$(cd "$dir" 2>/dev/null && pwd)" || {
            echo "Error: Directory not found: $dir"
            exit 1
        }
        # Get the basename for the mount point
        dir_name="$(basename "$abs_dir")"
        echo "Mounting $abs_dir -> /workspace/$dir_name"
        PODMAN_ARGS+=("-v" "$abs_dir:/workspace/$dir_name:z")
    done
else
    echo "No directories mounted. Use arguments to mount project directories."
    echo "Example: $0 ~/myproject"
fi

# Add FUSE overlay volumes
if [ ${#FUSE_VOLUME_ARGS[@]} -gt 0 ]; then
    PODMAN_ARGS+=("${FUSE_VOLUME_ARGS[@]}")
fi

# Add the image name
PODMAN_ARGS+=("$IMAGE_NAME")

echo ""
echo "=========================================="
if [[ "$CONTAINER_TAG" == opencode* ]]; then
echo "Starting OpenCode container ($CONTAINER_TAG)"
else
echo "Starting Claude Code container ($CONTAINER_TAG)"
fi
echo "=========================================="
echo ""
echo "Inside the container:"
if [[ "$CONTAINER_TAG" == opencode* ]]; then
echo "  - Run 'opencode' to start OpenCode"
else
echo "  - Run 'claude' to start Claude Code"
fi
echo "  - Run 'tmux' for terminal multiplexing"
echo "  - Your mounted directories are in /workspace/"
echo "  - You have root access - install packages, modify system, etc."
if [[ "$CONTAINER_TAG" == *gastown* ]]; then
echo "  - GasTown tools available: 'gt' and 'bd'"
fi
echo ""

# Run the container
exec podman "${PODMAN_ARGS[@]}"

#!/bin/bash
#
# Installer for claude-container.
#
# Installs the launcher script and bash completions, and builds the container
# image from this repository's claude-code/ Dockerfile, tagged with the version
# the launcher expects (shadowing the Docker Hub image of the same name, since
# this repo's Ubuntu-based image differs from upstream).
#
# Idempotent: safe to re-run. Files are overwritten in place, and the image
# build is a cached no-op when nothing changed.
#
# Usage:
#   ./install.sh                    # user install (~/.local) + image build
#   ./install.sh --system           # install to /usr/local/bin (uses sudo)
#   ./install.sh --bin-dir <dir>    # custom launcher location
#   ./install.sh --no-build         # skip the docker image build
#   ./install.sh --no-completions   # skip bash completion install

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output (match bin/claude-container)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BIN_DIR="$HOME/.local/bin"
COMPLETIONS_DIR="$HOME/.local/share/bash-completion/completions"
SYSTEM_INSTALL=false
BUILD_IMAGE=true
INSTALL_COMPLETIONS=true
SUDO=""

show_help() {
    cat << EOF
claude-container installer

Installs the launcher and bash completions, and builds the container image from
this repository (tagged so the launcher's default image name resolves locally).

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    --system                Install launcher to /usr/local/bin and completions
                            to /etc/bash_completion.d (uses sudo if needed)
    --bin-dir <dir>         Install launcher to <dir> (default: ~/.local/bin)
    --completions-dir <dir> Install completions to <dir>
                            (default: ~/.local/share/bash-completion/completions)
    --no-build              Skip building the docker image
    --no-completions        Skip installing bash completions
    -h, --help              Show this help message

The script is idempotent — re-running it overwrites the installed files in
place and re-uses docker's build cache, so it is also the update path after
pulling new changes.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --system)
            SYSTEM_INSTALL=true
            BIN_DIR="/usr/local/bin"
            COMPLETIONS_DIR="/etc/bash_completion.d"
            shift
            ;;
        --bin-dir)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: --bin-dir requires a directory${NC}"
                exit 1
            fi
            BIN_DIR="$2"
            shift 2
            ;;
        --completions-dir)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: --completions-dir requires a directory${NC}"
                exit 1
            fi
            COMPLETIONS_DIR="$2"
            shift 2
            ;;
        --no-build)
            BUILD_IMAGE=false
            shift
            ;;
        --no-completions)
            INSTALL_COMPLETIONS=false
            shift
            ;;
        *)
            echo -e "${RED}Error: unknown option '$1'${NC}"
            echo "Run ./install.sh --help for usage."
            exit 1
            ;;
    esac
done

if [ ! -f "$REPO_DIR/bin/claude-container" ]; then
    echo -e "${RED}Error: bin/claude-container not found next to install.sh — run from a repo checkout.${NC}"
    exit 1
fi

# The launcher's VERSION determines the image tag it looks for; build under the
# same tag so no Docker Hub pull is needed (or wanted — this repo's image
# replaces the upstream one).
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REPO_DIR/bin/claude-container" | head -1)"
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: could not read VERSION from bin/claude-container${NC}"
    exit 1
fi
IMAGE="nezhar/claude-container:${VERSION}"

if [ "$SYSTEM_INSTALL" = true ] && [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# --- Launcher -----------------------------------------------------------------
echo -e "${GREEN}Installing launcher to ${BIN_DIR}/claude-container${NC}"
$SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$REPO_DIR/bin/claude-container" "$BIN_DIR/claude-container"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo -e "${YELLOW}Note: $BIN_DIR is not in your PATH.${NC}"
        echo -e "${YELLOW}  bash/zsh: export PATH=\"$BIN_DIR:\$PATH\"${NC}"
        echo -e "${YELLOW}  fish:     fish_add_path $BIN_DIR${NC}"
        ;;
esac

# --- Completions ----------------------------------------------------------------
if [ "$INSTALL_COMPLETIONS" = true ]; then
    if [ -f "$REPO_DIR/completions/claude-container" ]; then
        echo -e "${GREEN}Installing bash completions to ${COMPLETIONS_DIR}/claude-container${NC}"
        $SUDO mkdir -p "$COMPLETIONS_DIR"
        $SUDO install -m 0644 "$REPO_DIR/completions/claude-container" "$COMPLETIONS_DIR/claude-container"
    else
        echo -e "${YELLOW}Warning: completions/claude-container not found; skipping completions.${NC}"
    fi
fi

# --- Image ----------------------------------------------------------------------
if [ "$BUILD_IMAGE" = true ]; then
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Error: Docker is not running or not accessible.${NC}"
        echo -e "${YELLOW}Start Docker and re-run ./install.sh (or use --no-build to skip the image).${NC}"
        exit 1
    fi
    echo -e "${GREEN}Building container image ${IMAGE} from claude-code/ ...${NC}"
    docker build -t "$IMAGE" -t nezhar/claude-container:latest "$REPO_DIR/claude-code"
    echo -e "${BLUE}Note: this local image shadows the Docker Hub tag of the same name;${NC}"
    echo -e "${BLUE}'claude-container --pull' would replace it with the upstream image.${NC}"
    echo -e "${BLUE}To update after changing claude-code/, just re-run ./install.sh.${NC}"
else
    echo -e "${BLUE}Skipping image build (--no-build). The launcher expects ${IMAGE}.${NC}"
fi

echo ""
echo -e "${GREEN}Done.${NC} Run '${YELLOW}claude-container${NC}' in a workspace to get started."

#!/usr/bin/env bash
# EasyInstall Ultra - Bootstrap Installer
# Remote:  curl -fsSL https://raw.githubusercontent.com/sugan0927/easy-install-Ultra/main/install.sh | sudo bash
# Local:   sudo bash install.sh

set -euo pipefail

REPO_URL="https://github.com/sugan0927/easy-install-Ultra"
INSTALL_DIR="/opt/EasyInstall-Ultra"
BRANCH="main"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${BOLD}${CYAN}"
echo "  ┌──────────────────────────────────────────┐"
echo "  │       EasyInstall Ultra Installer         │"
echo "  │   World's Fastest WordPress Optimizer     │"
echo "  └──────────────────────────────────────────┘"
echo -e "${NC}"

# Root check
[[ $EUID -ne 0 ]] && { echo -e "${RED}✗ Run as root: sudo bash install.sh${NC}"; exit 1; }

# OS check
if [[ -f /etc/os-release ]]; then
    ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
    PRETTY_NAME=$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release | tr -d '"')
    case "${ID}" in
        ubuntu|debian) echo -e "${GREEN}✓ OS: ${PRETTY_NAME}${NC}" ;;
        *) echo -e "${RED}✗ Unsupported OS. Use Ubuntu 22.04/24.04 or Debian 11/12${NC}"; exit 1 ;;
    esac
fi

# RAM check
RAM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
[[ $RAM_MB -lt 512 ]] && { echo -e "${RED}✗ Min 512MB RAM required (found: ${RAM_MB}MB)${NC}"; exit 1; }
echo -e "${GREEN}✓ RAM: ${RAM_MB}MB${NC}"

# Determine source: local directory (when run as bash install.sh) or GitHub
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if [[ -f "${SCRIPT_DIR}/easyinstall.sh" && -f "${SCRIPT_DIR}/config.py" ]]; then
    # ── LOCAL INSTALL (from zip / cloned repo) ──────────────────────────
    echo -e "${YELLOW}→ Installing from local directory: ${SCRIPT_DIR}${NC}"
    mkdir -p "$INSTALL_DIR"
    cp -r "${SCRIPT_DIR}/." "$INSTALL_DIR/"
else
    # ── REMOTE INSTALL (piped from curl) ────────────────────────────────
    echo -e "${YELLOW}→ Downloading EasyInstall Ultra from GitHub...${NC}"
    command -v git &>/dev/null || apt-get install -y -qq git
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        echo -e "${YELLOW}→ Updating existing installation...${NC}"
        git -C "$INSTALL_DIR" pull --quiet
    else
        git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR" --quiet
    fi
fi

chmod +x "${INSTALL_DIR}/easyinstall.sh"
chmod +x "${INSTALL_DIR}/config.py"
chmod +x "${INSTALL_DIR}/worker/deploy-worker.sh"

# Symlink CLI
ln -sfn "${INSTALL_DIR}/easyinstall.sh" /usr/local/bin/easyinstall
echo -e "${GREEN}✓ 'easyinstall' command installed${NC}"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  EasyInstall Ultra installed!            ║${NC}"
echo -e "${BOLD}${GREEN}║                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  Run full stack install:                 ║${NC}"
echo -e "${BOLD}${GREEN}║    sudo easyinstall install              ║${NC}"
echo -e "${BOLD}${GREEN}║                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  Create a WordPress site:                ║${NC}"
echo -e "${BOLD}${GREEN}║    sudo easyinstall create example.com   ║${NC}"
echo -e "${BOLD}${GREEN}║            --ssl --woocommerce           ║${NC}"
echo -e "${BOLD}${GREEN}║                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  Deploy Cloudflare Worker (optional):    ║${NC}"
echo -e "${BOLD}${GREEN}║    sudo easyinstall worker-deploy        ║${NC}"
echo -e "${BOLD}${GREEN}║            example.com                   ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

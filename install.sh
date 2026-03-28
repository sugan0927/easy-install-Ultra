#!/usr/bin/env bash
# EasyInstall Ultra - Bootstrap Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/youruser/EasyInstall-Ultra/main/install.sh | bash

set -euo pipefail

REPO_URL="https://github.com/youruser/EasyInstall-Ultra"
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

# Install git if needed
command -v git &>/dev/null || apt-get install -y -qq git

# Clone or update repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo -e "${YELLOW}→ Updating existing installation...${NC}"
    git -C "$INSTALL_DIR" pull --quiet
else
    echo -e "${YELLOW}→ Downloading EasyInstall Ultra...${NC}"
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR" --quiet
fi

chmod +x "${INSTALL_DIR}/easyinstall.sh"
chmod +x "${INSTALL_DIR}/config.py"

# Symlink CLI
ln -sfn "${INSTALL_DIR}/easyinstall.sh" /usr/local/bin/easyinstall
echo -e "${GREEN}✓ 'easyinstall' command installed${NC}"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  EasyInstall Ultra downloaded!           ║${NC}"
echo -e "${BOLD}${GREEN}║                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  Run full install:                       ║${NC}"
echo -e "${BOLD}${GREEN}║    easyinstall install                   ║${NC}"
echo -e "${BOLD}${GREEN}║                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  Create a site:                          ║${NC}"
echo -e "${BOLD}${GREEN}║    easyinstall create example.com        ║${NC}"
echo -e "${BOLD}${GREEN}║            --ssl --woocommerce           ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

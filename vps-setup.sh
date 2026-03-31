#!/usr/bin/env bash
# =============================================================================
# EasyInstall Ultra — Complete VPS Setup
# Source: https://github.com/sugan0927/easy-install-Ultra
#
# ONE COMMAND INSTALL:
#   curl -fsSL https://raw.githubusercontent.com/sugan0927/easy-install-Ultra/main/vps-setup.sh | sudo bash
#
# OR after downloading:
#   sudo bash vps-setup.sh
#   sudo bash vps-setup.sh --domain yourdomain.com --ssl --woocommerce
# =============================================================================

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────
DOMAIN=""
USE_SSL="false"
USE_WOO="false"
PHP_VER="8.3"
SKIP_WORKER="false"

for arg in "$@"; do
    [[ "$arg" =~ --domain=(.+) ]]  && DOMAIN="${BASH_REMATCH[1]}"
    [[ "$arg" == "--ssl" ]]         && USE_SSL="true"
    [[ "$arg" == "--woocommerce" ]] && USE_WOO="true"
    [[ "$arg" =~ --php=(.+) ]]     && PHP_VER="${BASH_REMATCH[1]}"
    [[ "$arg" == "--skip-worker" ]] && SKIP_WORKER="true"
done

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

REPO_URL="https://github.com/sugan0927/easy-install-Ultra"
INSTALL_DIR="/opt/EasyInstall-Ultra"

ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${YELLOW}→ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │     EasyInstall Ultra — Complete VPS Setup       │"
echo "  │  WordPress + Nginx + PHP + MariaDB + Redis       │"
echo "  │  Source: github.com/sugan0927/easy-install-Ultra │"
echo "  └─────────────────────────────────────────────────┘"
echo -e "${NC}"

# ─────────────────────────────────────────────────────────────
# STEP 0 — Preflight
# ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash vps-setup.sh"

# OS check
if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
    OS_VER=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')
    case "$OS_ID" in
        ubuntu) [[ "$OS_VER" =~ ^(22.04|24.04)$ ]] || die "Use Ubuntu 22.04 or 24.04" ;;
        debian) [[ "$OS_VER" =~ ^(11|12)$ ]]        || die "Use Debian 11 or 12" ;;
        *)      die "Unsupported OS: $OS_ID. Use Ubuntu 22.04/24.04 or Debian 11/12" ;;
    esac
    ok "OS: $OS_ID $OS_VER"
fi

RAM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
[[ $RAM_MB -lt 512 ]] && die "Minimum 512MB RAM required (found: ${RAM_MB}MB)"
ok "RAM: ${RAM_MB}MB"

# ─────────────────────────────────────────────────────────────
# STEP 1 — Install base dependencies
# ─────────────────────────────────────────────────────────────
info "Installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl wget git unzip zip gnupg2 lsb-release \
    ca-certificates apt-transport-https software-properties-common \
    python3 python3-pip python3-venv python3-full \
    ufw fail2ban cron logrotate net-tools jq bc
ok "Base dependencies installed"

# ─────────────────────────────────────────────────────────────
# STEP 2 — Install Node.js 20 LTS (needed for Wrangler / Worker deploy)
# ─────────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
    info "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - -qq
    apt-get install -y -qq nodejs
    ok "Node.js $(node --version) installed"
else
    ok "Node.js $(node --version) already present"
fi

# Install Wrangler CLI globally
if ! command -v wrangler &>/dev/null; then
    info "Installing Wrangler CLI..."
    npm install -g wrangler --quiet
    ok "Wrangler $(wrangler --version 2>/dev/null | head -1) installed"
else
    ok "Wrangler already installed"
fi

# ─────────────────────────────────────────────────────────────
# STEP 3 — Clone / update EasyInstall Ultra from GitHub
# ─────────────────────────────────────────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --quiet
    ok "Updated from GitHub"
else
    info "Cloning from ${REPO_URL}..."
    git clone --depth=1 "$REPO_URL" "$INSTALL_DIR" --quiet
    ok "Cloned successfully"
fi

chmod +x "${INSTALL_DIR}/easyinstall.sh"
chmod +x "${INSTALL_DIR}/config.py"
[[ -f "${INSTALL_DIR}/worker/deploy-worker.sh" ]] && \
    chmod +x "${INSTALL_DIR}/worker/deploy-worker.sh"

# Symlink CLI
ln -sfn "${INSTALL_DIR}/easyinstall.sh" /usr/local/bin/easyinstall
ok "'easyinstall' command ready"

# ─────────────────────────────────────────────────────────────
# STEP 4 — Run full stack install (Nginx + PHP + MariaDB + Redis)
# ─────────────────────────────────────────────────────────────
info "Running full WordPress stack install..."
easyinstall install
ok "WordPress stack installed"

# ─────────────────────────────────────────────────────────────
# STEP 5 — Create WordPress site (if --domain given)
# ─────────────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
    info "Creating WordPress site: ${DOMAIN}"
    SITE_CMD="easyinstall create ${DOMAIN} --php=${PHP_VER}"
    [[ "$USE_SSL" == "true" ]] && SITE_CMD+=" --ssl"
    [[ "$USE_WOO" == "true" ]] && SITE_CMD+=" --woocommerce"
    eval "$SITE_CMD"
    ok "WordPress site created: ${DOMAIN}"
else
    echo ""
    echo -e "${YELLOW}Tip: Create a site with:${NC}"
    echo "  sudo easyinstall create yourdomain.com --ssl --woocommerce"
fi

# ─────────────────────────────────────────────────────────────
# STEP 6 — Install Python venv for config.py
# ─────────────────────────────────────────────────────────────
info "Setting up Python environment for config generator..."
python3 -m venv /opt/easyinstall-venv
/opt/easyinstall-venv/bin/pip install -q jinja2 cryptography boto3 requests
ok "Python venv ready at /opt/easyinstall-venv"

# ─────────────────────────────────────────────────────────────
# STEP 7 — Cloudflare Worker setup instructions
# ─────────────────────────────────────────────────────────────
if [[ "$SKIP_WORKER" != "true" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Cloudflare Worker — Ready to Deploy${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Worker files are at: ${CYAN}${INSTALL_DIR}/worker/${NC}"
    echo ""
    echo "  OPTION A — Deploy from this VPS:"
    echo "    cd ${INSTALL_DIR}/worker"
    echo "    Edit wrangler.toml → set your domain"
    echo "    wrangler login"
    echo "    wrangler deploy"
    echo ""
    echo "  OPTION B — Deploy via Cloudflare Dashboard (easier):"
    echo "    1. Push repo to GitHub (already done: github.com/sugan0927/easy-install-Ultra)"
    echo "    2. Cloudflare Dashboard → Workers & Pages → Create"
    echo "    3. Connect to GitHub repo"
    echo "    4. Build command:   npx wrangler deploy"
    echo "    5. Root directory:  / (repo root)"
    echo ""

    if [[ -n "$DOMAIN" ]]; then
        echo "  OPTION C — Use easyinstall command:"
        echo "    sudo easyinstall worker-deploy ${DOMAIN}"
        echo ""
    fi
fi

# ─────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  VPS Setup Complete! ✓                               ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  Stack:    Nginx + PHP ${PHP_VER} + MariaDB + Redis        ║${NC}"
echo -e "${BOLD}${GREEN}║  CLI:      sudo easyinstall <command>                ║${NC}"
echo -e "${BOLD}${GREEN}║  Worker:   ${INSTALL_DIR}/worker/       ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  Quick commands:                                     ║${NC}"
echo -e "${BOLD}${GREEN}║    sudo easyinstall status                           ║${NC}"
echo -e "${BOLD}${GREEN}║    sudo easyinstall create yourdomain.com --ssl      ║${NC}"
echo -e "${BOLD}${GREEN}║    sudo easyinstall worker-deploy yourdomain.com     ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

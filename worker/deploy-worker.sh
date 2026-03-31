#!/usr/bin/env bash
# =============================================================================
# EasyInstall Ultra — Cloudflare Worker Deploy Script
# Usage: sudo bash deploy-worker.sh <your-domain.com>
# =============================================================================

set -euo pipefail

DOMAIN="${1:-}"
WORKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYINSTALL_DIR="$(dirname "$WORKER_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ┌─────────────────────────────────────────────────┐"
  echo "  │   EasyInstall Ultra — Cloudflare Worker Deploy   │"
  echo "  └─────────────────────────────────────────────────┘"
  echo -e "${NC}"
}

die()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${YELLOW}→ $*${NC}"; }

# ─────────────────────────────────────────────────────────────
# STEP 0 — Preflight checks
# ─────────────────────────────────────────────────────────────
preflight() {
  banner

  [[ -z "$DOMAIN" ]] && die "Usage: bash deploy-worker.sh <your-domain.com>"
  [[ ! -f "${WORKER_DIR}/worker.js" ]]     && die "worker.js not found in ${WORKER_DIR}"
  [[ ! -f "${WORKER_DIR}/wrangler.toml" ]] && die "wrangler.toml not found in ${WORKER_DIR}"

  echo -e "${BOLD}Domain:${NC} ${DOMAIN}"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# STEP 1 — Install Node.js 20 LTS + Wrangler CLI (on VPS)
# ─────────────────────────────────────────────────────────────
install_node_and_wrangler() {
  info "Checking Node.js..."

  if ! command -v node &>/dev/null || [[ "$(node -e 'process.exit(parseInt(process.version.slice(1))<20?1:0)' 2>/dev/null; echo $?)" == "1" ]]; then
    info "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
    ok "Node.js $(node --version) installed"
  else
    ok "Node.js $(node --version) already installed"
  fi

  if ! command -v wrangler &>/dev/null; then
    info "Installing Wrangler CLI..."
    npm install -g wrangler --quiet
    ok "Wrangler $(wrangler --version 2>/dev/null | head -1) installed"
  else
    ok "Wrangler $(wrangler --version 2>/dev/null | head -1) already installed"
  fi
}

# ─────────────────────────────────────────────────────────────
# STEP 2 — Patch wrangler.toml with real domain
# ─────────────────────────────────────────────────────────────
patch_wrangler_config() {
  info "Patching wrangler.toml for domain: ${DOMAIN}..."

  local toml="${WORKER_DIR}/wrangler.toml"
  local toml_bak="${toml}.bak"

  cp "$toml" "$toml_bak"

  # Substitute placeholder domain
  sed -i "s/YOUR_DOMAIN\.COM/${DOMAIN}/g" "$toml"

  # Prompt for account ID if still placeholder
  if grep -q "YOUR_ACCOUNT_ID" "$toml"; then
    echo ""
    echo -e "${BOLD}Find your Cloudflare Account ID:${NC}"
    echo "  → https://dash.cloudflare.com → right sidebar → 'Account ID'"
    echo ""
    read -rp "Enter your Cloudflare Account ID: " CF_ACCOUNT_ID
    [[ -z "$CF_ACCOUNT_ID" ]] && die "Account ID required"
    sed -i "s/YOUR_ACCOUNT_ID/${CF_ACCOUNT_ID}/" "$toml"
  fi

  ok "wrangler.toml patched"
}

# ─────────────────────────────────────────────────────────────
# STEP 3 — Create KV namespace for login rate limiting
# ─────────────────────────────────────────────────────────────
setup_kv_namespace() {
  info "Setting up KV namespace for login rate limiting..."

  # Check if already configured
  if ! grep -q "REPLACE_WITH_KV_NAMESPACE_ID" "${WORKER_DIR}/wrangler.toml"; then
    ok "KV namespace already configured"
    return
  fi

  echo ""
  info "Creating KV namespace 'LOGIN_KV'..."
  local kv_output
  kv_output=$(cd "$WORKER_DIR" && wrangler kv:namespace create "LOGIN_KV" 2>&1) || {
    echo -e "${YELLOW}⚠ Could not auto-create KV namespace.${NC}"
    echo "  Run manually: cd worker && wrangler kv:namespace create LOGIN_KV"
    echo "  Then paste the 'id' into wrangler.toml"
    return
  }

  # Extract the KV id from wrangler output
  local kv_id
  kv_id=$(echo "$kv_output" | grep -oP '(?<=id = ")[^"]+')
  if [[ -n "$kv_id" ]]; then
    sed -i "s/REPLACE_WITH_KV_NAMESPACE_ID/${kv_id}/" "${WORKER_DIR}/wrangler.toml"
    ok "KV namespace created (id: ${kv_id})"
  else
    echo -e "${YELLOW}⚠ Could not parse KV id. Paste it manually in wrangler.toml${NC}"
  fi
}

# ─────────────────────────────────────────────────────────────
# STEP 4 — Set Worker secrets
# ─────────────────────────────────────────────────────────────
setup_secrets() {
  info "Setting up Worker secrets..."
  echo ""

  # Check if already logged in to wrangler
  if ! wrangler whoami &>/dev/null 2>&1; then
    echo -e "${BOLD}Cloudflare login required:${NC}"
    cd "$WORKER_DIR" && wrangler login
  fi

  echo ""
  echo -e "${BOLD}Set the purge webhook secret:${NC}"
  echo "  This secret is used by WordPress to authenticate cache purge requests."
  echo "  It must match what you put in your WordPress functions.php"
  echo ""

  # Generate a random secret if user doesn't have one
  local suggested
  suggested=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 2>/dev/null || echo "change-me-$(date +%s)")
  echo -e "  Suggested secret: ${CYAN}${suggested}${NC}"
  echo ""

  cd "$WORKER_DIR"
  if echo "$suggested" | wrangler secret put PURGE_WEBHOOK_SECRET 2>/dev/null; then
    ok "PURGE_WEBHOOK_SECRET set"
    PURGE_SECRET="$suggested"
  else
    echo -e "${YELLOW}⚠ Set secret manually: cd worker && wrangler secret put PURGE_WEBHOOK_SECRET${NC}"
    PURGE_SECRET="(set manually)"
  fi
}

# ─────────────────────────────────────────────────────────────
# STEP 5 — Deploy the Worker
# ─────────────────────────────────────────────────────────────
deploy_worker() {
  info "Deploying Worker to Cloudflare edge..."
  echo ""

  cd "$WORKER_DIR"
  if wrangler deploy; then
    ok "Worker deployed successfully!"
  else
    die "Worker deploy failed. Check errors above."
  fi
}

# ─────────────────────────────────────────────────────────────
# STEP 6 — Add WordPress purge hook instructions
# ─────────────────────────────────────────────────────────────
print_wordpress_integration() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  WordPress Integration — Add to functions.php${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo ""
  cat << PHPCODE
<?php
// EasyInstall Ultra — Cloudflare Worker Cache Purge
// Add this to: /var/www/${DOMAIN}/public/wp-content/themes/YOUR-THEME/functions.php

define('CF_PURGE_SECRET', '${PURGE_SECRET:-YOUR_PURGE_SECRET}');
define('CF_PURGE_URL',    'https://${DOMAIN}/cf-purge');

function easyinstall_cf_purge(\$url) {
    wp_remote_post(CF_PURGE_URL, [
        'body'    => json_encode(['url' => \$url, 'secret' => CF_PURGE_SECRET]),
        'headers' => ['Content-Type' => 'application/json'],
        'timeout' => 5,
    ]);
}

// Purge on post publish/update
add_action('save_post', function(\$post_id) {
    if (wp_is_post_revision(\$post_id) || wp_is_post_autosave(\$post_id)) return;
    easyinstall_cf_purge(get_permalink(\$post_id));
    // Also purge homepage and archives
    easyinstall_cf_purge(home_url('/'));
    easyinstall_cf_purge(home_url('/blog/'));
});

// Purge on comment post
add_action('comment_post', function(\$comment_id) {
    \$comment = get_comment(\$comment_id);
    easyinstall_cf_purge(get_permalink(\$comment->comment_post_ID));
});
PHPCODE
  echo ""
}

# ─────────────────────────────────────────────────────────────
# STEP 7 — Cloudflare Dashboard settings reminder
# ─────────────────────────────────────────────────────────────
print_cloudflare_settings() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Cloudflare Dashboard — Recommended Settings${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${BOLD}SSL/TLS:${NC}"
  echo "    → Mode: Full (Strict)"
  echo "    → Always Use HTTPS: ON"
  echo "    → HSTS: ON (max-age=31536000, includeSubDomains)"
  echo ""
  echo -e "  ${BOLD}Speed:${NC}"
  echo "    → Auto Minify: CSS ✓  JS ✓  HTML ✓"
  echo "    → Brotli: ON"
  echo "    → Early Hints: ON"
  echo "    → HTTP/2: ON"
  echo "    → HTTP/3 (with QUIC): ON"
  echo ""
  echo -e "  ${BOLD}Caching:${NC}"
  echo "    → Caching Level: Standard"
  echo "    → Browser Cache TTL: Respect Existing Headers"
  echo ""
  echo -e "  ${BOLD}Security:${NC}"
  echo "    → Bot Fight Mode: ON"
  echo "    → Security Level: Medium"
  echo "    → WAF: ON (if on paid plan)"
  echo ""
  echo -e "  ${BOLD}Network:${NC}"
  echo "    → TCP Acceleration (Argo): Optional (paid)"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# STEP 8 — Update easyinstall commands
# ─────────────────────────────────────────────────────────────
register_worker_commands() {
  info "Saving worker config to /etc/easyinstall/worker.conf..."
  mkdir -p /etc/easyinstall
  cat > /etc/easyinstall/worker.conf << EOF
DOMAIN=${DOMAIN}
WORKER_DIR=${WORKER_DIR}
DEPLOYED=$(date +%Y-%m-%d)
EOF
  chmod 600 /etc/easyinstall/worker.conf
  ok "Worker config saved"
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
PURGE_SECRET=""

preflight
install_node_and_wrangler
patch_wrangler_config
setup_kv_namespace
setup_secrets
deploy_worker
register_worker_commands
print_wordpress_integration
print_cloudflare_settings

echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Cloudflare Worker deployed successfully! 🚀       ║${NC}"
echo -e "${BOLD}${GREEN}║                                                   ║${NC}"
echo -e "${BOLD}${GREEN}║  Edge cache:    Active on ${DOMAIN}         ║${NC}"
echo -e "${BOLD}${GREEN}║  Rate limiting: wp-login.php (5 attempts/5min)   ║${NC}"
echo -e "${BOLD}${GREEN}║  Cache purge:   https://${DOMAIN}/cf-purge  ║${NC}"
echo -e "${BOLD}${GREEN}║  Health check:  https://${DOMAIN}/cf-health ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

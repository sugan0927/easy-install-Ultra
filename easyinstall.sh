#!/usr/bin/env bash
# =============================================================================
# EasyInstall Ultra - World's Fastest WordPress Optimizer
# Version: 2.0.0
# PHP Default: 8.3 | Features: WooCommerce, Cloudflare, S3 Backup
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────
# GLOBALS & CONSTANTS
# ─────────────────────────────────────────────
readonly VERSION="2.0.0"
readonly SCRIPT_NAME="EasyInstall Ultra"
readonly LOG_DIR="/var/log/easyinstall"
readonly LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/var/run/easyinstall.lock"
readonly BACKUP_DIR="/var/backups/easyinstall"
readonly CONFIG_DIR="/etc/easyinstall"
readonly WEB_ROOT="/var/www"
readonly DEFAULT_PHP="8.3"
readonly SUPPORTED_PHP_VERSIONS=("8.2" "8.3" "8.4")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Hardware detection (populated by detect_hardware)
TOTAL_RAM_MB=0
TOTAL_CORES=0
DISK_TYPE="SSD"
CLOUD_PROVIDER="unknown"
OS_ID=""
OS_VERSION=""

# ─────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────
setup_logging() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "INFO" "EasyInstall Ultra v${VERSION} started"
}

log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} ${message}" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} ${message}" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} ${message}" ;;
        DEBUG) [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} ${message}" ;;
    esac
}

print_banner() {
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
 ___  ___  ________  ________      ___  ________   ________  _________  ________  ___       ___
|\  \|\  \|\   __  \|\   ____\    |\  \|\   ___  \|\   ____\|\___   ___\\   __  \|\  \     |\  \
\ \  \\\  \ \  \|\  \ \  \___|    \ \  \ \  \\ \  \ \  \___|\|___ \  \_\ \  \|\  \ \  \    \ \  \
 \ \  \\\  \ \   __  \ \_____  \   \ \  \ \  \\ \  \ \_____  \   \ \  \ \ \   __  \ \  \    \ \  \
  \ \  \\\  \ \  \ \  \|____|\  \   \ \  \ \  \\ \  \|____|\  \   \ \  \ \ \  \ \  \ \  \____\ \  \____
   \ \_______\ \__\ \__\____\_\  \   \ \__\ \__\\ \__\____\_\  \   \ \__\ \ \__\ \__\ \_______\ \_______\
    \|_______|\|__|\|__|\_________\   \|__|\|__| \|__|\_________\   \|__|  \|__|\|__|\|_______|\|_______|
                       \|_________|                   \|_________|
EOF
    echo -e "${NC}"
    echo -e "${BOLD}                     World's Fastest WordPress Optimizer v${VERSION}${NC}"
    echo -e "${CYAN}                     PHP 8.3 | WooCommerce | Cloudflare | S3 Backup${NC}"
    echo ""
}

# ─────────────────────────────────────────────
# LOCK FILE MANAGEMENT
# ─────────────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "ERROR" "Another instance is running (PID: $pid). Exiting."
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap release_lock EXIT INT TERM
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ─────────────────────────────────────────────
# HARDWARE DETECTION
# ─────────────────────────────────────────────
detect_hardware() {
    log "INFO" "Detecting server hardware..."

    # RAM
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    # CPU Cores
    TOTAL_CORES=$(nproc --all)

    # Disk Type
    local root_device
    root_device=$(lsblk -no pkname $(df / | awk 'NR==2{print $1}') 2>/dev/null | head -1)
    if [[ -n "$root_device" ]]; then
        local rotational
        rotational=$(cat "/sys/block/${root_device}/queue/rotational" 2>/dev/null || echo "0")
        DISK_TYPE=$([[ "$rotational" == "0" ]] && echo "SSD" || echo "HDD")
    fi

    # Cloud Provider Detection
    if curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/ami-id &>/dev/null; then
        CLOUD_PROVIDER="aws"
    elif curl -sf --max-time 2 http://169.254.169.254/metadata/v1/id &>/dev/null; then
        CLOUD_PROVIDER="digitalocean"
    elif curl -sf --max-time 2 http://169.254.169.254/v1/metadata &>/dev/null; then
        CLOUD_PROVIDER="hetzner"
    elif curl -sf --max-time 2 http://metadata.google.internal/ &>/dev/null; then
        CLOUD_PROVIDER="gcp"
    elif [[ -f /sys/class/dmi/id/sys_vendor ]]; then
        local vendor
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
        [[ "$vendor" == *"Linode"* ]] && CLOUD_PROVIDER="linode"
        [[ "$vendor" == *"Vultr"* ]]  && CLOUD_PROVIDER="vultr"
    fi

    # OS Detection (grep instead of source to avoid readonly variable conflicts)
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
        OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')
    fi

    log "INFO" "Hardware: ${TOTAL_RAM_MB}MB RAM | ${TOTAL_CORES} cores | ${DISK_TYPE} | ${CLOUD_PROVIDER} | ${OS_ID} ${OS_VERSION}"
}

# ─────────────────────────────────────────────
# OS COMPATIBILITY CHECK
# ─────────────────────────────────────────────
check_os_compatibility() {
    log "INFO" "Checking OS compatibility..."

    case "${OS_ID}" in
        ubuntu)
            case "${OS_VERSION}" in
                22.04|24.04) log "INFO" "Ubuntu ${OS_VERSION} - Supported ✓" ;;
                *) log "ERROR" "Ubuntu ${OS_VERSION} not supported. Use 22.04 or 24.04"; exit 1 ;;
            esac ;;
        debian)
            case "${OS_VERSION}" in
                11|12) log "INFO" "Debian ${OS_VERSION} - Supported ✓" ;;
                *) log "ERROR" "Debian ${OS_VERSION} not supported. Use 11 or 12"; exit 1 ;;
            esac ;;
        *)
            log "ERROR" "OS '${OS_ID}' not supported. Use Ubuntu 22.04/24.04 or Debian 11/12"
            exit 1 ;;
    esac

    [[ $EUID -ne 0 ]] && { log "ERROR" "Must run as root"; exit 1; }
    [[ "$TOTAL_RAM_MB" -lt 512 ]] && { log "ERROR" "Minimum 512MB RAM required (found: ${TOTAL_RAM_MB}MB)"; exit 1; }
}

# ─────────────────────────────────────────────
# RETRY LOGIC
# ─────────────────────────────────────────────
retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    local cmd=("$@")

    while [[ $attempt -le $max_attempts ]]; do
        if "${cmd[@]}"; then
            return 0
        fi
        log "WARN" "Attempt ${attempt}/${max_attempts} failed for: ${cmd[*]}"
        sleep $((delay * attempt))
        ((attempt++))
    done

    log "ERROR" "All ${max_attempts} attempts failed for: ${cmd[*]}"
    return 1
}

# ─────────────────────────────────────────────
# PACKAGE MANAGEMENT
# ─────────────────────────────────────────────
install_base_dependencies() {
    log "INFO" "Installing base dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    retry apt-get update -qq
    retry apt-get install -y -qq \
        curl wget gnupg2 lsb-release ca-certificates \
        software-properties-common apt-transport-https \
        python3 python3-pip python3-venv python3-full \
        git unzip zip tar gzip \
        ufw fail2ban \
        cron logrotate \
        net-tools htop iotop \
        jq bc

    log "INFO" "Base dependencies installed ✓"
}

# ─────────────────────────────────────────────
# REPOSITORY SETUP
# ─────────────────────────────────────────────
setup_nginx_repo() {
    log "INFO" "Adding Nginx official mainline repository..."

    local keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o "$keyring"
    chmod 644 "$keyring"

    local codename
    codename=$(lsb_release -cs)
    echo "deb [signed-by=${keyring}] http://nginx.org/packages/mainline/${OS_ID} ${codename} nginx" \
        > /etc/apt/sources.list.d/nginx.list

    # Pin nginx from official repo
    cat > /etc/apt/preferences.d/99nginx << 'EOF'
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF
    log "INFO" "Nginx repo added ✓"
}

setup_php_repo() {
    log "INFO" "Adding PHP (Ondřej Surý) repository..."

    if [[ "$OS_ID" == "ubuntu" ]]; then
        retry add-apt-repository -y ppa:ondrej/php
    else
        curl -fsSL https://packages.sury.org/php/apt.gpg \
            | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] \
            https://packages.sury.org/php/ $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/php.list
    fi
    log "INFO" "PHP repo added ✓"
}

setup_mariadb_repo() {
    log "INFO" "Adding MariaDB 11.x official repository..."

    curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- \
        --mariadb-server-version=mariadb-11.4 --skip-maxscale --skip-tools

    log "INFO" "MariaDB repo added ✓"
}

setup_redis_repo() {
    log "INFO" "Adding Redis 7.x official repository..."

    curl -fsSL https://packages.redis.io/gpg \
        | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
        https://packages.redis.io/deb $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/redis.list

    log "INFO" "Redis repo added ✓"
}

setup_all_repos() {
    setup_nginx_repo
    setup_php_repo
    setup_mariadb_repo
    setup_redis_repo
    retry apt-get update -qq
}

# ─────────────────────────────────────────────
# NGINX INSTALLATION
# ─────────────────────────────────────────────
install_nginx() {
    log "INFO" "Installing Nginx with modules..."

    retry apt-get install -y -qq \
        nginx \
        libnginx-mod-http-brotli-filter \
        libnginx-mod-http-brotli-static \
        libnginx-mod-http-geoip2

    systemctl enable nginx
    log "INFO" "Nginx installed ✓"
}

# ─────────────────────────────────────────────
# PHP INSTALLATION
# ─────────────────────────────────────────────
install_php() {
    local php_version="${1:-$DEFAULT_PHP}"
    log "INFO" "Installing PHP ${php_version} with extensions..."

    local extensions=(
        "php${php_version}-fpm"
        "php${php_version}-cli"
        "php${php_version}-common"
        "php${php_version}-mysql"
        "php${php_version}-xml"
        "php${php_version}-xmlrpc"
        "php${php_version}-curl"
        "php${php_version}-gd"
        "php${php_version}-imagick"
        "php${php_version}-mbstring"
        "php${php_version}-soap"
        "php${php_version}-intl"
        "php${php_version}-bcmath"
        "php${php_version}-zip"
        "php${php_version}-opcache"
        "php${php_version}-redis"
        "php${php_version}-apcu"
        "php${php_version}-igbinary"
    )

    retry apt-get install -y -qq "${extensions[@]}"

    systemctl enable "php${php_version}-fpm"
    log "INFO" "PHP ${php_version} installed with all extensions ✓"
}

# ─────────────────────────────────────────────
# MARIADB INSTALLATION
# ─────────────────────────────────────────────
install_mariadb() {
    log "INFO" "Installing MariaDB 11.4..."

    export DEBIAN_FRONTEND=noninteractive
    retry apt-get install -y -qq mariadb-server mariadb-client

    systemctl enable mariadb
    systemctl start mariadb

    # Secure installation (non-interactive)
    local root_password
    root_password=$(generate_password 32)
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_password}';"
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "FLUSH PRIVILEGES;"

    echo "[client]
user=root
password=${root_password}" > /root/.my.cnf
    chmod 600 /root/.my.cnf

    log "INFO" "MariaDB installed and secured ✓"
}

# ─────────────────────────────────────────────
# REDIS INSTALLATION
# ─────────────────────────────────────────────
install_redis() {
    log "INFO" "Installing Redis 7.x..."

    retry apt-get install -y -qq redis-server

    systemctl enable redis-server
    log "INFO" "Redis installed ✓"
}

# ─────────────────────────────────────────────
# CERTBOT (SSL)
# ─────────────────────────────────────────────
install_certbot() {
    log "INFO" "Installing Certbot for SSL..."

    if [[ "$OS_ID" == "ubuntu" ]]; then
        retry apt-get install -y -qq certbot python3-certbot-nginx
    else
        retry apt-get install -y -qq certbot python3-certbot-nginx
    fi

    # Auto-renewal cron
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'nginx -s reload'") | crontab -
    fi

    log "INFO" "Certbot installed with auto-renewal ✓"
}

# ─────────────────────────────────────────────
# PYTHON CONFIG GENERATOR
# ─────────────────────────────────────────────
run_python_config() {
    log "INFO" "Running Python configuration generator..."

    # Setup Python venv
    python3 -m venv /opt/easyinstall-venv
    /opt/easyinstall-venv/bin/pip install -q jinja2 cryptography boto3 requests

    # Run config generator
    /opt/easyinstall-venv/bin/python3 "$(dirname "$0")/config.py" \
        --ram-mb="$TOTAL_RAM_MB" \
        --cores="$TOTAL_CORES" \
        --disk-type="$DISK_TYPE" \
        --php-version="$DEFAULT_PHP" \
        --features="woocommerce,cloudflare,s3"

    log "INFO" "Python configuration generated ✓"
}

# ─────────────────────────────────────────────
# KERNEL TUNING
# ─────────────────────────────────────────────
tune_kernel() {
    log "INFO" "Applying kernel performance tuning..."

    cat > /etc/sysctl.d/99-wordpress.conf << 'EOF'
# EasyInstall Ultra - Kernel Performance Tuning

# TCP BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# File descriptor limits
fs.file-max = 2097152
fs.nr_open = 2097152

# Reduce swappiness
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Network buffers
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 9

# TCP timeouts
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Increase connection backlog
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000

# IP forwarding off (security)
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF

    sysctl -p /etc/sysctl.d/99-wordpress.conf &>/dev/null

    # File descriptor limits
    cat >> /etc/security/limits.conf << 'EOF'
# EasyInstall Ultra
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
www-data soft nofile 1048576
www-data hard nofile 1048576
EOF

    # Enable BBR
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr
        echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
    fi

    log "INFO" "Kernel tuning applied ✓"
}

# ─────────────────────────────────────────────
# SECURITY SETUP
# ─────────────────────────────────────────────
setup_firewall() {
    log "INFO" "Configuring UFW firewall..."

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 443/udp comment 'HTTP/3 QUIC'

    # Rate limiting for SSH
    ufw limit ssh

    ufw --force enable

    log "INFO" "UFW firewall configured ✓"
}

setup_fail2ban() {
    log "INFO" "Configuring Fail2ban for WordPress..."

    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd
banaction = iptables-multiport

[sshd]
enabled = true
port    = ssh
filter  = sshd
maxretry = 3

[nginx-http-auth]
enabled  = true

[nginx-limit-req]
enabled  = true
filter   = nginx-limit-req
action   = iptables-multiport[name=ReqLimit, port="http,https", protocol=tcp]
logpath  = /var/log/nginx/error.log
findtime = 600
bantime  = 7200
maxretry = 10

[wordpress-login]
enabled  = true
filter   = wordpress
logpath  = /var/log/nginx/*/access.log
findtime = 300
bantime  = 86400
maxretry = 5
EOF

    cat > /etc/fail2ban/filter.d/wordpress.conf << 'EOF'
[Definition]
failregex = ^<HOST>.*"POST /wp-login.php
            ^<HOST>.*"POST /xmlrpc.php
ignoreregex =
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    log "INFO" "Fail2ban configured ✓"
}

# ─────────────────────────────────────────────
# WORDPRESS INSTALLATION
# ─────────────────────────────────────────────
generate_password() {
    local length="${1:-24}"
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c "$length"
}

create_wordpress_site() {
    local domain="$1"
    local php_version="${2:-$DEFAULT_PHP}"
    local ssl="${3:-false}"
    local woocommerce="${4:-false}"

    log "INFO" "Creating WordPress site: ${domain}"

    local site_dir="${WEB_ROOT}/${domain}"
    local db_name
    db_name="wp_$(echo "$domain" | tr '.' '_' | tr '-' '_' | head -c 20)"
    local db_user
    db_user="u_$(echo "$domain" | tr '.' '_' | tr '-' '_' | head -c 12)"
    local db_pass
    db_pass=$(generate_password 24)
    local wp_table_prefix
    wp_table_prefix="wp$(tr -dc 'a-z' </dev/urandom | head -c 4)_"

    # Create directories
    mkdir -p "${site_dir}/public"
    mkdir -p "${site_dir}/logs"
    mkdir -p "${site_dir}/cache"
    mkdir -p "${site_dir}/backups"

    # Download WordPress
    log "INFO" "Downloading WordPress..."
    curl -fsSL "https://wordpress.org/latest.tar.gz" | tar -xzC "/tmp/"
    cp -r /tmp/wordpress/. "${site_dir}/public/"
    rm -rf /tmp/wordpress

    # Create database
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # Generate wp-config.php
    generate_wp_config "${site_dir}/public" "$db_name" "$db_user" "$db_pass" "$wp_table_prefix"

    # Nginx site config
    generate_nginx_site_config "$domain" "$php_version" "$site_dir"

    # PHP-FPM pool
    generate_php_pool_config "$domain" "$php_version"

    # Set permissions
    chown -R www-data:www-data "${site_dir}"
    find "${site_dir}/public" -type f -exec chmod 644 {} \;
    find "${site_dir}/public" -type d -exec chmod 755 {} \;
    chmod 600 "${site_dir}/public/wp-config.php"

    # Enable site
    nginx -t && systemctl reload nginx

    # SSL setup
    if [[ "$ssl" == "true" ]]; then
        setup_ssl "$domain"
    fi

    # WooCommerce optimization
    if [[ "$woocommerce" == "true" ]]; then
        apply_woocommerce_optimizations "$domain" "$php_version"
    fi

    # Save site config
    mkdir -p "${CONFIG_DIR}/sites"
    cat > "${CONFIG_DIR}/sites/${domain}.conf" << EOF
DOMAIN=${domain}
SITE_DIR=${site_dir}
DB_NAME=${db_name}
DB_USER=${db_user}
PHP_VERSION=${php_version}
SSL=${ssl}
WOOCOMMERCE=${woocommerce}
CREATED=$(date +%Y-%m-%d)
EOF

    log "INFO" "WordPress site created: ${domain} ✓"
    echo ""
    echo -e "${GREEN}✓ WordPress installed successfully!${NC}"
    echo -e "  ${BOLD}URL:${NC}      http://${domain}"
    echo -e "  ${BOLD}DB Name:${NC}  ${db_name}"
    echo -e "  ${BOLD}DB User:${NC}  ${db_user}"
    echo -e "  ${BOLD}DB Pass:${NC}  ${db_pass}"
    echo -e "  ${BOLD}WP Table:${NC} ${wp_table_prefix}"
    echo ""
    echo -e "${YELLOW}→ Complete setup at: http://${domain}/wp-admin/install.php${NC}"
}

generate_wp_config() {
    local public_dir="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local table_prefix="$5"

    # Generate unique keys from WordPress secret key API
    local wp_keys
    wp_keys=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null || echo "// Keys unavailable - regenerate at https://api.wordpress.org/secret-key/1.1/salt/")

    cat > "${public_dir}/wp-config.php" << EOF
<?php
/**
 * EasyInstall Ultra - WordPress Configuration
 * Optimized for maximum performance
 */

// Database
define('DB_NAME',      '${db_name}');
define('DB_USER',      '${db_user}');
define('DB_PASSWORD',  '${db_pass}');
define('DB_HOST',      '127.0.0.1');
define('DB_CHARSET',   'utf8mb4');
define('DB_COLLATE',   'utf8mb4_unicode_ci');

\$table_prefix = '${table_prefix}';

// Performance
define('WP_MEMORY_LIMIT',     '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
define('WP_CACHE',            true);

// Redis Object Cache
define('WP_REDIS_HOST',          '127.0.0.1');
define('WP_REDIS_PORT',          6379);
define('WP_REDIS_DATABASE',      1);
define('WP_REDIS_PREFIX',        '${table_prefix}');
define('WP_REDIS_SCHEME',        'tcp');
define('WP_REDIS_SERIALIZER',    Redis::SERIALIZER_IGBINARY);
define('WP_REDIS_MAXTTL',        86400);
define('WP_REDIS_TIMEOUT',       1);
define('WP_REDIS_READ_TIMEOUT',  1);

// Security
define('DISALLOW_FILE_EDIT',   true);
define('DISALLOW_FILE_MODS',   false);
define('FORCE_SSL_ADMIN',      false);
define('WP_DEBUG',             false);
define('WP_DEBUG_LOG',         false);
define('WP_DEBUG_DISPLAY',     false);

// Uploads & Paths
define('UPLOADS',  'wp-content/uploads');
define('AUTOSAVE_INTERVAL', 300);
define('WP_POST_REVISIONS',  5);
define('EMPTY_TRASH_DAYS',   14);

// WooCommerce Performance
define('WC_LOG_HANDLER', 'WC_Log_Handler_DB');

// Multisite (disabled by default)
// define('WP_ALLOW_MULTISITE', true);

// Disable XML-RPC pingbacks
add_filter('xmlrpc_enabled', '__return_false');

// Auth keys (generated)
${wp_keys}

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
EOF
}

generate_nginx_site_config() {
    local domain="$1"
    local php_version="$2"
    local site_dir="$3"
    local php_sock="/run/php/php${php_version}-fpm-${domain}.sock"

    cat > "/etc/nginx/sites-available/${domain}" << EOF
# EasyInstall Ultra - ${domain}
# FastCGI Microcache zone
fastcgi_cache_path /var/run/nginx-cache/${domain}
    levels=1:2
    keys_zone=${domain//./_}:100m
    max_size=1g
    inactive=60m
    use_temp_path=off;

server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${site_dir}/public;
    index index.php index.html;

    # Logging
    access_log ${site_dir}/logs/access.log combined buffer=512k flush=1m;
    error_log  ${site_dir}/logs/error.log warn;

    # Cloudflare Real IP
    include /etc/nginx/conf.d/cloudflare-realip.conf;

    # Security headers
    include /etc/nginx/conf.d/security-headers.conf;

    # FastCGI cache settings
    set \$skip_cache 0;
    if (\$request_method = POST)            { set \$skip_cache 1; }
    if (\$query_string != "")              { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap") {
        set \$skip_cache 1;
    }
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") {
        set \$skip_cache 1;
    }

    # WordPress permalink support
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # PHP processing
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:${php_sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;

        # FastCGI cache
        fastcgi_cache ${domain//./_};
        fastcgi_cache_valid 200 301 302 60m;
        fastcgi_cache_valid 404 1m;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
        fastcgi_cache_use_stale error timeout invalid_header http_500;
        fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
        add_header X-FastCGI-Cache \$upstream_cache_status;

        fastcgi_connect_timeout 60;
        fastcgi_send_timeout    180;
        fastcgi_read_timeout    180;
        fastcgi_buffer_size     128k;
        fastcgi_buffers         256 16k;
        fastcgi_busy_buffers_size 256k;
    }

    # Static file caching
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2|ttf|eot)$ {
        expires     1y;
        add_header  Cache-Control "public, immutable";
        add_header  Vary "Accept-Encoding";
        access_log  off;
        log_not_found off;
    }

    # Security: Block sensitive files
    location ~* /(wp-config.php|wp-settings.php|readme.html|license.txt|xmlrpc.php) {
        deny all;
        return 404;
    }

    # Block PHP in uploads
    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }

    # Block hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # wp-login.php rate limiting
    location = /wp-login.php {
        limit_req zone=one burst=3 nodelay;
        include fastcgi_params;
        fastcgi_pass unix:${php_sock};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    # Brotli & Gzip compression
    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    # Cache purge endpoint
    location ~ /purge(/.*) {
        allow 127.0.0.1;
        deny all;
        fastcgi_cache_purge ${domain//./_} "\$scheme\$request_method\$host\$1";
    }
}
EOF

    mkdir -p "/var/run/nginx-cache/${domain}"
    chown www-data:www-data "/var/run/nginx-cache/${domain}"
    ln -sfn "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}"
}

generate_php_pool_config() {
    local domain="$1"
    local php_version="$2"
    local pool_name
    pool_name=$(echo "$domain" | tr '.' '_')

    cat > "/etc/php/${php_version}/fpm/pool.d/${pool_name}.conf" << EOF
[${pool_name}]
user  = www-data
group = www-data

listen = /run/php/php${php_version}-fpm-${domain}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

; Dynamic process management
pm = dynamic
pm.max_children      = $(php_max_children)
pm.start_servers     = $(( $(php_max_children) / 4 ))
pm.min_spare_servers = $(( $(php_max_children) / 4 ))
pm.max_spare_servers = $(( $(php_max_children) / 2 ))
pm.max_requests      = 500
pm.process_idle_timeout = 10s

; Logging
access.log = /var/www/${domain}/logs/php-fpm.log
slowlog    = /var/www/${domain}/logs/php-slow.log
request_slowlog_timeout = 5s

; Security
security.limit_extensions = .php
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source
php_admin_value[open_basedir] = /var/www/${domain}/public:/tmp:/usr/share/php
php_admin_value[error_log]    = /var/www/${domain}/logs/php-error.log

; Performance overrides
php_admin_value[memory_limit]          = $(php_memory_limit)
php_admin_value[max_execution_time]    = 120
php_admin_value[max_input_vars]        = 10000
php_admin_value[post_max_size]         = 64M
php_admin_value[upload_max_filesize]   = 64M
EOF

    systemctl reload "php${php_version}-fpm"
}

# ─────────────────────────────────────────────
# CALCULATED PERFORMANCE VALUES
# ─────────────────────────────────────────────
php_max_children() {
    echo $(( TOTAL_RAM_MB / 64 < 5 ? 5 : (TOTAL_RAM_MB / 64 > 160 ? 160 : TOTAL_RAM_MB / 64) ))
}

php_memory_limit() {
    local limit=$(( TOTAL_RAM_MB / 4 ))
    echo "${limit}M"
}

# ─────────────────────────────────────────────
# SSL SETUP
# ─────────────────────────────────────────────
setup_ssl() {
    local domain="$1"
    log "INFO" "Setting up SSL for ${domain}..."

    if certbot --nginx -d "$domain" -d "www.${domain}" \
        --non-interactive --agree-tos \
        --email "admin@${domain}" \
        --redirect; then
        log "INFO" "SSL certificate obtained for ${domain} ✓"
    else
        log "WARN" "SSL setup failed. Run: certbot --nginx -d ${domain}"
    fi
}

# ─────────────────────────────────────────────
# WOOCOMMERCE OPTIMIZATIONS
# ─────────────────────────────────────────────
apply_woocommerce_optimizations() {
    local domain="$1"
    local php_version="$2"

    log "INFO" "Applying WooCommerce optimizations for ${domain}..."

    # Nginx WooCommerce cache rules (skip cart, checkout, account)
    cat >> "/etc/nginx/sites-available/${domain}" << 'EOF'

    # WooCommerce - Do not cache
    set $woo_no_cache 0;
    if ($request_uri ~* "/(cart|checkout|my-account|addons|/?add-to-cart=)") {
        set $woo_no_cache 1;
    }
    if ($http_cookie ~* "woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session") {
        set $woo_no_cache 1;
    }
EOF

    # Increase PHP limits for WooCommerce
    local pool_name
    pool_name=$(echo "$domain" | tr '.' '_')
    sed -i 's/max_execution_time.*= 120/max_execution_time    = 300/' \
        "/etc/php/${php_version}/fpm/pool.d/${pool_name}.conf"

    systemctl reload "php${php_version}-fpm"
    nginx -t && systemctl reload nginx

    log "INFO" "WooCommerce optimizations applied ✓"
}

# ─────────────────────────────────────────────
# BACKUP SYSTEM
# ─────────────────────────────────────────────
create_backup() {
    local domain="$1"
    local backup_type="${2:-daily}"

    log "INFO" "Creating ${backup_type} backup for ${domain}..."

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="${BACKUP_DIR}/${domain}/${backup_type}"
    mkdir -p "$backup_path"

    local backup_file="${backup_path}/${domain}-${timestamp}.tar.gz"
    local db_file="${backup_path}/${domain}-${timestamp}.sql.gz"

    # Read site config
    source "${CONFIG_DIR}/sites/${domain}.conf" 2>/dev/null || {
        log "ERROR" "Site config not found: ${domain}"
        return 1
    }

    # Database backup
    mysqldump --single-transaction --quick --lock-tables=false \
        "$DB_NAME" | gzip > "$db_file"

    # Files backup
    tar -czf "$backup_file" \
        -C "${SITE_DIR}" public \
        --exclude="public/wp-content/cache" \
        --exclude="public/wp-content/updraft"

    log "INFO" "Backup created: ${backup_file}"

    # Retention policy
    local keep_days=7
    [[ "$backup_type" == "weekly" ]]  && keep_days=30
    [[ "$backup_type" == "monthly" ]] && keep_days=365

    find "$backup_path" -name "*.tar.gz" -mtime "+${keep_days}" -delete
    find "$backup_path" -name "*.sql.gz" -mtime "+${keep_days}" -delete

    log "INFO" "${backup_type} backup completed ✓"
}

setup_backup_cron() {
    # Daily backup at 2 AM
    (crontab -l 2>/dev/null; echo "0 2 * * * easyinstall backup daily >> ${LOG_DIR}/backup.log 2>&1") | crontab -
    # Weekly backup Sunday 3 AM
    (crontab -l 2>/dev/null; echo "0 3 * * 0 easyinstall backup weekly >> ${LOG_DIR}/backup.log 2>&1") | crontab -
    log "INFO" "Backup cron jobs configured ✓"
}

# ─────────────────────────────────────────────
# S3 BACKUP SUPPORT
# ─────────────────────────────────────────────
setup_s3_backup() {
    local domain="$1"
    local s3_bucket="$2"
    local aws_key="$3"
    local aws_secret="$4"
    local aws_region="${5:-us-east-1}"

    log "INFO" "Configuring S3 backup for ${domain}..."

    # Install AWS CLI
    if ! command -v aws &>/dev/null; then
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
        unzip -q /tmp/awscliv2.zip -d /tmp/
        /tmp/aws/install
        rm -rf /tmp/awscliv2.zip /tmp/aws
    fi

    # Save S3 config
    mkdir -p "${CONFIG_DIR}/s3"
    cat > "${CONFIG_DIR}/s3/${domain}.conf" << EOF
S3_BUCKET=${s3_bucket}
AWS_KEY=${aws_key}
AWS_SECRET=${aws_secret}
AWS_REGION=${aws_region}
EOF
    chmod 600 "${CONFIG_DIR}/s3/${domain}.conf"

    log "INFO" "S3 backup configured for ${domain} ✓"
}

s3_upload_backup() {
    local domain="$1"
    local backup_file="$2"

    [[ ! -f "${CONFIG_DIR}/s3/${domain}.conf" ]] && {
        log "WARN" "S3 not configured for ${domain}"
        return 0
    }

    source "${CONFIG_DIR}/s3/${domain}.conf"

    AWS_ACCESS_KEY_ID="$AWS_KEY" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
    aws s3 cp "$backup_file" "s3://${S3_BUCKET}/easyinstall/${domain}/" \
        --region "$AWS_REGION" --quiet

    log "INFO" "Backup uploaded to S3: s3://${S3_BUCKET}/easyinstall/${domain}/"
}

# ─────────────────────────────────────────────
# CACHE MANAGEMENT
# ─────────────────────────────────────────────
purge_cache() {
    local domain="${1:-all}"

    if [[ "$domain" == "all" ]]; then
        find /var/run/nginx-cache/ -type f -delete
        redis-cli FLUSHALL
        log "INFO" "All caches purged ✓"
    else
        rm -rf "/var/run/nginx-cache/${domain}/"
        mkdir -p "/var/run/nginx-cache/${domain}"
        chown www-data:www-data "/var/run/nginx-cache/${domain}"
        log "INFO" "Cache purged for ${domain} ✓"
    fi
}

warm_cache() {
    local domain="$1"
    log "INFO" "Warming cache for ${domain}..."

    local sitemap_url="https://${domain}/sitemap.xml"
    if curl -sfI "$sitemap_url" &>/dev/null; then
        curl -fsSL "$sitemap_url" | grep -oP '(?<=<loc>)[^<]+' | while read -r url; do
            curl -sfL "$url" -o /dev/null -w "  Warmed: %{url_effective} (%{time_total}s)\n"
        done
    else
        curl -sfL "https://${domain}/" -o /dev/null
        log "WARN" "No sitemap found, warmed homepage only"
    fi

    log "INFO" "Cache warming complete for ${domain} ✓"
}

# ─────────────────────────────────────────────
# STATUS & MONITORING
# ─────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo -e "${BOLD}    EasyInstall Ultra - System Status   ${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo ""

    local services=("nginx" "mariadb" "redis-server" "fail2ban")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} ${svc} - ${GREEN}Running${NC}"
        else
            echo -e "  ${RED}●${NC} ${svc} - ${RED}Stopped${NC}"
        fi
    done

    # PHP-FPM
    for ver in "${SUPPORTED_PHP_VERSIONS[@]}"; do
        if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} php${ver}-fpm - ${GREEN}Running${NC}"
        fi
    done

    echo ""
    echo -e "${BOLD}  Resources:${NC}"
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local mem_used
    mem_used=$(free -m | awk '/Mem:/{printf "%.0f", $3/$2*100}')
    local disk_used
    disk_used=$(df / | awk 'NR==2{print $5}')

    echo -e "  CPU:  ${cpu_usage}%"
    echo -e "  RAM:  ${mem_used}%"
    echo -e "  Disk: ${disk_used}"

    echo ""
    echo -e "${BOLD}  Sites:${NC}"
    if [[ -d "${CONFIG_DIR}/sites" ]]; then
        for conf in "${CONFIG_DIR}/sites/"*.conf; do
            [[ -f "$conf" ]] || continue
            source "$conf"
            echo -e "  → ${DOMAIN} (PHP ${PHP_VERSION})"
        done
    fi
    echo ""
}

# ─────────────────────────────────────────────
# PERFORMANCE BENCHMARK
# ─────────────────────────────────────────────
run_benchmark() {
    local domain="${1:-localhost}"
    log "INFO" "Running performance benchmark for ${domain}..."

    if ! command -v ab &>/dev/null; then
        apt-get install -y -qq apache2-utils
    fi

    echo -e "\n${BOLD}Running benchmarks...${NC}"
    echo "────────────────────────────────────────"

    # TTFB test
    local ttfb
    ttfb=$(curl -sfL -o /dev/null -w "%{time_starttransfer}" "https://${domain}/" 2>/dev/null || echo "N/A")
    echo -e "TTFB:            ${GREEN}${ttfb}s${NC}"

    # Requests per second
    ab -n 1000 -c 50 -q "https://${domain}/" 2>/dev/null | grep -E "Requests per second|Time per request|Failed requests" || true

    echo "────────────────────────────────────────"
    log "INFO" "Benchmark complete ✓"
}

# ─────────────────────────────────────────────
# MANAGEMENT CLI
# ─────────────────────────────────────────────
print_usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} easyinstall <command> [options]"
    echo ""
    echo -e "${BOLD}Site Management:${NC}"
    echo "  create <domain> [--php=8.3] [--ssl] [--woocommerce]"
    echo "  delete <domain>"
    echo "  list"
    echo "  info <domain>"
    echo ""
    echo -e "${BOLD}SSL:${NC}"
    echo "  ssl <domain>"
    echo "  ssl-renew"
    echo ""
    echo -e "${BOLD}Backup:${NC}"
    echo "  backup [daily|weekly] <domain>"
    echo "  restore <domain> <backup-file>"
    echo "  s3-setup <domain> <bucket> <key> <secret>"
    echo ""
    echo -e "${BOLD}Performance:${NC}"
    echo "  optimize"
    echo "  warm-cache <domain>"
    echo "  purge-cache [domain]"
    echo "  benchmark [domain]"
    echo ""
    echo -e "${BOLD}Monitoring:${NC}"
    echo "  status"
    echo "  logs [domain]"
    echo "  health"
    echo ""
    echo -e "${BOLD}PHP:${NC}"
    echo "  php-switch <domain> <version>"
    echo "  php-status"
    echo ""
    echo -e "${BOLD}Cache:${NC}"
    echo "  redis-status"
    echo "  redis-flush [domain]"
    echo ""
}

# CLI dispatcher
handle_command() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        install)
            print_banner
            acquire_lock
            setup_logging
            detect_hardware
            check_os_compatibility
            install_base_dependencies
            setup_all_repos
            apt-get update -qq
            install_nginx
            install_php "$DEFAULT_PHP"
            install_mariadb
            install_redis
            install_certbot
            tune_kernel
            setup_firewall
            setup_fail2ban
            run_python_config
            setup_backup_cron
            show_status
            log "INFO" "EasyInstall Ultra installation complete! ✓"
            ;;

        create)
            local domain="${1:-}"
            [[ -z "$domain" ]] && { echo "Usage: easyinstall create <domain> [--php=8.3] [--ssl] [--woocommerce]"; exit 1; }
            local php_ver="$DEFAULT_PHP"
            local ssl="false"
            local woocommerce="false"
            for arg in "$@"; do
                [[ "$arg" =~ --php=(.+) ]]       && php_ver="${BASH_REMATCH[1]}"
                [[ "$arg" == "--ssl" ]]           && ssl="true"
                [[ "$arg" == "--woocommerce" ]]   && woocommerce="true"
            done
            create_wordpress_site "$domain" "$php_ver" "$ssl" "$woocommerce"
            ;;

        delete)
            local domain="${1:-}"
            [[ -z "$domain" ]] && { echo "Usage: easyinstall delete <domain>"; exit 1; }
            read -rp "Are you sure you want to delete ${domain}? [y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
            source "${CONFIG_DIR}/sites/${domain}.conf"
            rm -f "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}"
            mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
            mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';"
            rm -rf "/var/www/${domain}" "${CONFIG_DIR}/sites/${domain}.conf"
            nginx -t && systemctl reload nginx
            log "INFO" "Site ${domain} deleted ✓"
            ;;

        list)
            echo -e "\n${BOLD}Installed WordPress Sites:${NC}"
            shopt -s nullglob
            for conf in "${CONFIG_DIR}/sites/"*.conf; do
                [[ -f "$conf" ]] || continue
                source "$conf"
                echo -e "  → ${DOMAIN} (PHP ${PHP_VERSION}) - Created: ${CREATED}"
            done
            shopt -u nullglob
            ;;

        ssl) setup_ssl "${1:-}" ;;
        ssl-renew) certbot renew --quiet ;;

        backup) create_backup "${2:-all}" "${1:-daily}" ;;

        restore)
            local domain="${1:-}"; local backup_file="${2:-}"
            [[ -z "$domain" || -z "$backup_file" ]] && { echo "Usage: easyinstall restore <domain> <backup-file>"; exit 1; }
            source "${CONFIG_DIR}/sites/${domain}.conf"
            tar -xzf "$backup_file" -C "${SITE_DIR}"
            log "INFO" "Site ${domain} restored from ${backup_file} ✓"
            ;;

        s3-setup) setup_s3_backup "$@" ;;

        optimize)
            tune_kernel
            run_python_config
            nginx -t && systemctl reload nginx
            log "INFO" "System optimization applied ✓"
            ;;

        warm-cache) warm_cache "${1:-}" ;;
        purge-cache) purge_cache "${1:-all}" ;;
        benchmark) run_benchmark "${1:-localhost}" ;;

        status) show_status ;;

        logs)
            local domain="${1:-}"
            if [[ -n "$domain" ]]; then
                tail -f "/var/www/${domain}/logs/access.log" "/var/www/${domain}/logs/error.log"
            else
                tail -f "$LOG_FILE"
            fi
            ;;

        health)
            local exit_code=0
            for svc in nginx mariadb redis-server; do
                systemctl is-active --quiet "$svc" || { echo "FAIL: ${svc} not running"; exit_code=1; }
            done
            [[ $exit_code -eq 0 ]] && echo "All services healthy ✓"
            exit $exit_code
            ;;

        redis-status)
            redis-cli info server | grep -E "redis_version|uptime"
            redis-cli info memory | grep -E "used_memory_human|maxmemory_human"
            ;;

        redis-flush) redis-cli FLUSHALL ;;

        php-switch)
            local domain="${1:-}"; local new_ver="${2:-}"
            [[ -z "$domain" || -z "$new_ver" ]] && { echo "Usage: easyinstall php-switch <domain> <version>"; exit 1; }
            generate_php_pool_config "$domain" "$new_ver"
            generate_nginx_site_config "$domain" "$new_ver" "/var/www/${domain}"
            nginx -t && systemctl reload nginx
            log "INFO" "PHP switched to ${new_ver} for ${domain} ✓"
            ;;

        php-status)
            for ver in "${SUPPORTED_PHP_VERSIONS[@]}"; do
                systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null && \
                    echo "PHP ${ver}: Running" || echo "PHP ${ver}: Not installed"
            done
            ;;

        help|--help|-h|"") print_usage ;;
        *) echo "Unknown command: ${command}"; print_usage; exit 1 ;;
    esac
}

# ─────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────
main() {
    handle_command "${@:-help}"
}

main "$@"

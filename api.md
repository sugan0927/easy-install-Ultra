# EasyInstall Ultra — API & Developer Documentation

## Python Config API

The `config.py` module can be used programmatically to generate configurations:

### HardwareProfile

```python
from config import HardwareProfile

hw = HardwareProfile(
    ram_mb=4096,
    cores=4,
    disk_type="SSD",   # or "HDD"
    php_version="8.3"
)

# Access calculated values
print(hw.php_max_children)       # → 64
print(hw.php_memory_limit)       # → "1024M"
print(hw.php_opcache_memory)     # → 512
print(hw.mysql_buffer_pool_mb)   # → 2048
print(hw.redis_max_memory_mb)    # → 1024
print(hw.nginx_worker_connections)  # → 16384

# Get full summary as dict
summary = hw.summary()
```

### Configurators

```python
from config import HardwareProfile, NginxConfigurator, PHPConfigurator

hw = HardwareProfile(ram_mb=2048, cores=2)

# Generate nginx.conf string
nginx = NginxConfigurator(hw)
print(nginx.main_conf())

# Generate all Nginx configs to disk
nginx.write_all()

# Generate PHP configs
php = PHPConfigurator(hw)
print(php.opcache_ini())
php.write_all()
```

### CLI Usage

```bash
# Generate configs with custom hardware values
python3 config.py --ram-mb=8192 --cores=8 --disk-type=SSD --php-version=8.3

# Dry run (print values, don't write files)
python3 config.py --dry-run --ram-mb=4096 --cores=4

# Output summary to JSON
python3 config.py --dry-run --output-json=/tmp/config.json

# Enable specific feature sets
python3 config.py --features=woocommerce,cloudflare,s3
```

---

## Bash API

### Utility Functions (source easyinstall.sh)

```bash
source /opt/EasyInstall-Ultra/easyinstall.sh

# Detect hardware
detect_hardware
echo "$TOTAL_RAM_MB MB, $TOTAL_CORES cores, $DISK_TYPE"

# Generate password
pass=$(generate_password 32)

# Retry any command (3 attempts, exponential backoff)
retry apt-get install -y nginx

# Logging
log "INFO"  "Something worked"
log "WARN"  "Something might be wrong"
log "ERROR" "Something failed"
```

---

## Cache Purge API

Purge FastCGI cache via HTTP request:

```bash
# Purge single URL (from localhost)
curl -X PURGE http://localhost/your-page/

# Purge with Host header (for multi-site)
curl -X PURGE -H "Host: example.com" http://localhost/your-page/

# Programmatic purge via PHP (add to functions.php)
function easyinstall_purge_url($url) {
    $parsed = parse_url($url);
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, "http://127.0.0.1" . $parsed['path']);
    curl_setopt($ch, CURLOPT_CUSTOMREQUEST, "PURGE");
    curl_setopt($ch, CURLOPT_HTTPHEADER, ["Host: " . $parsed['host']]);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_exec($ch);
    curl_close($ch);
}

// Auto-purge on post save
add_action('save_post', function($post_id) {
    easyinstall_purge_url(get_permalink($post_id));
});
```

---

## S3 Backup API

```bash
# Configure S3 for a site
easyinstall s3-setup example.com \
    my-backup-bucket \
    AKIAIOSFODNN7EXAMPLE \
    wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
    us-east-1

# Trigger manual S3 backup
easyinstall backup daily example.com
# (Backup is auto-uploaded to S3 after creation)
```

S3 config is stored in `/etc/easyinstall/s3/example.com.conf` (chmod 600).

---

## Site Config Schema

Each site's config is stored in `/etc/easyinstall/sites/DOMAIN.conf`:

```bash
DOMAIN=example.com
SITE_DIR=/var/www/example.com
DB_NAME=wp_example_com
DB_USER=u_example_com
PHP_VERSION=8.3
SSL=true
WOOCOMMERCE=false
CREATED=2025-01-15
```

Parse in shell:
```bash
source /etc/easyinstall/sites/example.com.conf
echo "DB: $DB_NAME on PHP $PHP_VERSION"
```

---

## Monitoring API

```bash
# Health check (returns JSON)
/usr/local/bin/easyinstall-health

# Returns:
{
  "timestamp": "2025-01-15T10:30:00",
  "services": {
    "nginx": true,
    "mariadb": true,
    "redis": true,
    "fail2ban": true
  },
  "resources": {
    "disk_pct": 42.1,
    "mem_pct": 61.3
  }
}

# Use in scripts
health=$(easyinstall-health)
nginx_ok=$(echo $health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['services']['nginx'])")
```

---

## Extending EasyInstall Ultra

### Add a Custom Command

Add a new case to the `handle_command()` function in `easyinstall.sh`:

```bash
my-custom-command)
    log "INFO" "Running my custom command..."
    # your code here
    ;;
```

### Add a Custom Config Generator

Create a new class in `config.py`:

```python
class MyConfigurator:
    def __init__(self, hw: HardwareProfile):
        self.hw = hw

    def generate(self) -> str:
        return f"# My custom config\nvalue = {self.hw.ram_mb // 2}\n"

    def write_all(self) -> None:
        path = "/etc/myservice/myservice.conf"
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(self.generate())
        print(f"  ✓ Written: {path}")
```

Then add it to `main()` in `config.py`:

```python
sections = [
    # ... existing sections ...
    ("MyService", MyConfigurator(hw)),
]
```

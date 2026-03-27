# EasyInstall Ultra — Performance Tuning Guide

## Table of Contents
1. [How Auto-Tuning Works](#how-auto-tuning-works)
2. [PHP Optimization](#php-optimization)
3. [Nginx FastCGI Cache](#nginx-fastcgi-cache)
4. [MariaDB Tuning](#mariadb-tuning)
5. [Redis Object Cache](#redis-object-cache)
6. [Kernel & Network](#kernel--network)
7. [WooCommerce Specific](#woocommerce-specific)
8. [High-Traffic Blog](#high-traffic-blog)
9. [API Server Tuning](#api-server-tuning)

---

## How Auto-Tuning Works

When you run `easyinstall install`, the Python config generator (`config.py`) reads your server's hardware and calculates optimal settings:

```python
# From config.py - HardwareProfile class
php_max_children      = max(5,   min(160,  ram_mb // 64))
php_memory_limit      = f"{min(1024, ram_mb // 4)}M"
mysql_buffer_pool_mb  = min(2048, max(64, ram_mb // 2))
redis_max_memory_mb   = min(2048, max(64, ram_mb // 4))
nginx_worker_connections = min(16384, ram_mb * 4)
```

To re-generate configs after hardware upgrade:
```bash
easyinstall optimize
```

---

## PHP Optimization

### OPcache + JIT

OPcache caches compiled PHP bytecode. JIT (Just-In-Time) compiles hot code paths to native machine code.

**Key settings** (`/etc/php/8.3/mods-available/opcache.ini`):

```ini
opcache.validate_timestamps = 0     # Never re-check files (best for production)
opcache.jit                 = tracing  # Most aggressive JIT mode
opcache.jit_buffer_size     = 64M   # Increase for complex apps
opcache.memory_consumption  = 256   # Increase if "opcache.full" errors appear
```

**Check OPcache status:**
```bash
php8.3 -r "print_r(opcache_get_status());" | grep -E "hit_rate|memory"
```

### PHP-FPM Workers

Workers handle PHP requests. Too few = slow under load. Too many = OOM.

Rule of thumb: `max_children = available_ram / avg_worker_ram`

Check average worker RAM:
```bash
ps --no-headers -o "rss,cmd" -C php-fpm8.3 | awk '{sum+=$1} END {print sum/NR/1024 "MB avg"}'
```

Then adjust `/etc/php/8.3/fpm/pool.d/your-site.conf`:
```ini
pm.max_children = 30   # adjust based on measurement
```

### PHP Memory Limit

For WooCommerce or heavy plugins, increase:
```ini
php_admin_value[memory_limit] = 512M
```

---

## Nginx FastCGI Cache

FastCGI cache stores complete PHP responses. Cached responses bypass PHP entirely.

### Cache Location & Size

```nginx
# /etc/nginx/sites-available/example.com
fastcgi_cache_path /var/run/nginx-cache/example.com
    levels=1:2
    keys_zone=example_com:100m    # 100m = ~800k cached URLs
    max_size=1g                   # Max disk space
    inactive=60m;                 # Evict if not accessed in 60min
```

### Cache Bypass Rules

Customize what should NOT be cached:

```nginx
set $skip_cache 0;

# Skip for POST requests
if ($request_method = POST)     { set $skip_cache 1; }

# Skip for query strings (search, filters)
if ($query_string != "")        { set $skip_cache 1; }

# Skip for admin, login
if ($request_uri ~* "/wp-admin/|/wp-login.php") { set $skip_cache 1; }

# Skip for logged-in users (cookie)
if ($http_cookie ~* "wordpress_logged_in") { set $skip_cache 1; }
```

### Cache Lifetime

```nginx
fastcgi_cache_valid 200 301 302 60m;  # Cache 200/301/302 for 60 minutes
fastcgi_cache_valid 404 1m;           # Cache 404 for 1 minute
```

Increase to `24h` for static blogs with rare updates.

### Purge Cache Programmatically

```bash
# Purge single URL
curl -X PURGE http://localhost/your-url/

# Purge all (use sparingly)
easyinstall purge-cache example.com
```

---

## MariaDB Tuning

### InnoDB Buffer Pool

The most important setting. Caches data and indexes in RAM.

```ini
# /etc/mysql/mariadb.conf.d/99-wordpress.cnf
innodb_buffer_pool_size = 1G        # Rule: 60-80% of available RAM if DB-only server
innodb_buffer_pool_instances = 4    # 1 per GB of buffer pool
```

Check buffer pool hit rate (should be > 99%):
```sql
SELECT (1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)) * 100
AS buffer_pool_hit_rate
FROM information_schema.GLOBAL_STATUS
WHERE Variable_name IN ('Innodb_buffer_pool_reads', 'Innodb_buffer_pool_read_requests');
```

### Query Cache

Good for read-heavy WordPress sites, bad for write-heavy WooCommerce:

```ini
query_cache_type = 1      # Enable
query_cache_size = 128M   # WP blogs: increase; WooCommerce: set to 0
```

Disable for WooCommerce:
```ini
query_cache_type = 0
query_cache_size = 0
```

### Slow Query Log

```ini
slow_query_log          = 1
slow_query_log_file     = /var/log/mysql/slow-queries.log
long_query_time         = 2      # Log queries > 2 seconds
```

Analyze slow queries:
```bash
mysqldumpslow -s t -t 20 /var/log/mysql/slow-queries.log
```

---

## Redis Object Cache

Redis stores WordPress object cache (DB query results, computed values).

### WordPress Configuration

In `wp-config.php`:
```php
define('WP_REDIS_HOST',       '127.0.0.1');
define('WP_REDIS_PORT',       6379);
define('WP_REDIS_DATABASE',   1);      // Use DB 1 (0 is default)
define('WP_REDIS_PREFIX',     'site1_'); // Unique per site
define('WP_REDIS_SERIALIZER', Redis::SERIALIZER_IGBINARY);
define('WP_REDIS_MAXTTL',     86400);  // 24h max TTL
```

### Monitor Redis

```bash
# Real-time stats
redis-cli monitor

# Key statistics
redis-cli info stats | grep -E "hit|miss|evict"

# Memory usage
redis-cli info memory | grep used_memory_human

# Hit rate (should be > 80%)
redis-cli info stats | grep keyspace_hits
```

### Redis Eviction Policy

`allkeys-lru` evicts least recently used keys when memory is full — ideal for cache.

For sites with critical data in Redis (sessions), use `volatile-lru` instead:
```bash
redis-cli config set maxmemory-policy volatile-lru
```

---

## Kernel & Network

### TCP BBR

BBR congestion control improves throughput on high-latency connections:

```bash
# Verify BBR is active
sysctl net.ipv4.tcp_congestion_control
# Expected: net.ipv4.tcp_congestion_control = bbr

# Verify fq qdisc
tc qdisc show dev eth0
# Should show: qdisc fq ...
```

### File Descriptors

Under high traffic, you may hit fd limits:

```bash
# Check current limits
ulimit -n

# Check actual usage
cat /proc/sys/fs/file-nr
# Output: open  0  max
```

If hitting limits, `/etc/security/limits.conf` already has `1048576` set by EasyInstall.

---

## WooCommerce Specific

WooCommerce has unique caching requirements because cart/checkout pages must be dynamic.

### Recommended Settings

```bash
# Create WooCommerce-optimized site
easyinstall create shop.example.com --ssl --woocommerce
```

This automatically:
1. Bypasses FastCGI cache for `/cart`, `/checkout`, `/my-account`
2. Bypasses cache for `woocommerce_*` cookies
3. Sets PHP `max_execution_time = 300` (for complex orders)
4. Stores WooCommerce sessions in Redis

### PHP Limits for WooCommerce

```ini
php_admin_value[memory_limit]       = 512M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars]     = 10000  # Required for variable products
```

### MariaDB for WooCommerce

Disable query cache (WooCommerce writes frequently):
```ini
query_cache_type = 0
query_cache_size = 0
```

Add to `/etc/mysql/mariadb.conf.d/99-wordpress.cnf`.

---

## High-Traffic Blog

For news sites or blogs with high read traffic:

### Increase FastCGI Cache Time

```nginx
fastcgi_cache_valid 200 301 302 24h;  # Cache for 24 hours
```

### Serve Stale Cache on Backend Errors

```nginx
fastcgi_cache_use_stale error timeout invalid_header http_500 updating;
fastcgi_cache_background_update on;
fastcgi_cache_lock on;
```

### Aggressive OPcache

```ini
opcache.validate_timestamps = 0      # Never re-validate
opcache.max_accelerated_files = 30000
opcache.memory_consumption = 512
```

---

## API Server Tuning

If WordPress is used as a headless CMS or REST API backend:

### Disable FastCGI Cache for API Routes

```nginx
if ($request_uri ~* "^/wp-json/") {
    set $skip_cache 1;
}
```

### Increase PHP Worker Count

API requests are typically faster than page loads, so more workers help:

```ini
pm.max_children = 80    # Higher than default
pm.max_requests = 1000  # More requests per worker before respawn
```

### Redis for API Responses

Cache expensive REST API responses with a plugin like WP REST Cache, configured to use the Redis object cache.

---

## Re-running Auto-Tuning

After adding RAM or changing requirements:

```bash
# Re-generate all configs based on current hardware
easyinstall optimize

# Or run the Python generator directly with custom values
python3 /opt/EasyInstall-Ultra/config.py \
    --ram-mb=8192 \
    --cores=8 \
    --php-version=8.3 \
    --features=woocommerce,cloudflare,s3
```

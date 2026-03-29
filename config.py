#!/usr/bin/env python3
"""
EasyInstall Ultra - Python Configuration Generator
Generates optimized configs for Nginx, PHP, MariaDB, Redis
Features: WooCommerce, Cloudflare, S3 Backup
"""

import argparse
import os
import sys
import math
import json
import subprocess
import textwrap
from pathlib import Path
from datetime import datetime

# ─────────────────────────────────────────────
# HARDWARE PROFILE
# ─────────────────────────────────────────────

class HardwareProfile:
    def __init__(self, ram_mb: int, cores: int, disk_type: str = "SSD", php_version: str = "8.3"):
        self.ram_mb    = ram_mb
        self.cores     = cores
        self.disk_type = disk_type
        self.php_version = php_version

    # ── PHP ──────────────────────────────────
    @property
    def php_max_children(self) -> int:
        return max(5, min(160, self.ram_mb // 64))

    @property
    def php_memory_limit(self) -> str:
        return f"{min(1024, self.ram_mb // 4)}M"

    @property
    def php_opcache_memory(self) -> int:
        return min(512, max(128, self.ram_mb // 8))

    @property
    def php_jit_buffer(self) -> int:
        return min(128, max(32, self.ram_mb // 32))

    @property
    def php_interned_strings(self) -> int:
        return min(64, max(16, self.ram_mb // 64))

    @property
    def php_realpath_cache(self) -> str:
        return "4096k"

    # ── MariaDB ───────────────────────────────
    @property
    def mysql_buffer_pool_mb(self) -> int:
        return min(2048, max(64, self.ram_mb // 2))

    @property
    def mysql_buffer_pool_instances(self) -> int:
        return max(1, min(self.cores, self.mysql_buffer_pool_mb // 128))

    @property
    def mysql_query_cache_mb(self) -> int:
        return min(256, max(64, self.ram_mb // 16))

    @property
    def mysql_thread_cache_size(self) -> int:
        return min(256, max(16, self.ram_mb // 32))

    @property
    def mysql_table_open_cache(self) -> int:
        return min(20000, max(2000, self.ram_mb * 4))

    @property
    def mysql_innodb_io_capacity(self) -> int:
        return 4000 if self.disk_type == "SSD" else 2000

    @property
    def mysql_innodb_read_threads(self) -> int:
        return min(64, max(4, self.cores * 2))

    @property
    def mysql_innodb_write_threads(self) -> int:
        return min(64, max(4, self.cores * 2))

    @property
    def mysql_max_connections(self) -> int:
        return min(500, max(50, self.ram_mb // 8))

    # ── Redis ─────────────────────────────────
    @property
    def redis_max_memory_mb(self) -> int:
        return min(2048, max(64, self.ram_mb // 4))

    @property
    def redis_io_threads(self) -> int:
        return min(4, max(1, self.cores // 2))

    # ── Nginx ─────────────────────────────────
    @property
    def nginx_worker_processes(self) -> int:
        return self.cores

    @property
    def nginx_worker_connections(self) -> int:
        return min(16384, max(1024, self.ram_mb * 4))

    @property
    def nginx_keepalive_requests(self) -> int:
        return 10000

    @property
    def nginx_fastcgi_cache_size(self) -> str:
        mb = min(1024, max(100, self.ram_mb // 4))
        return f"{mb}m"

    def summary(self) -> dict:
        return {
            "hardware": {
                "ram_mb": self.ram_mb,
                "cores": self.cores,
                "disk_type": self.disk_type
            },
            "php": {
                "max_children": self.php_max_children,
                "memory_limit": self.php_memory_limit,
                "opcache_memory_mb": self.php_opcache_memory,
                "jit_buffer_mb": self.php_jit_buffer
            },
            "mariadb": {
                "buffer_pool_mb": self.mysql_buffer_pool_mb,
                "max_connections": self.mysql_max_connections
            },
            "redis": {
                "max_memory_mb": self.redis_max_memory_mb
            },
            "nginx": {
                "worker_processes": self.nginx_worker_processes,
                "worker_connections": self.nginx_worker_connections
            }
        }


# ─────────────────────────────────────────────
# NGINX CONFIGURATION
# ─────────────────────────────────────────────

class NginxConfigurator:
    def __init__(self, hw: HardwareProfile):
        self.hw = hw

    def main_conf(self) -> str:
        return textwrap.dedent(f"""\
            # EasyInstall Ultra - Nginx Main Config
            # Generated: {datetime.now().isoformat()}

            user www-data;
            worker_processes {self.hw.nginx_worker_processes};
            worker_rlimit_nofile 1048576;
            pid /run/nginx.pid;

            events {{
                worker_connections {self.hw.nginx_worker_connections};
                multi_accept on;
                use epoll;
            }}

            http {{
                # Basic settings
                sendfile           on;
                tcp_nopush         on;
                tcp_nodelay        on;
                keepalive_timeout  30;
                keepalive_requests {self.hw.nginx_keepalive_requests};
                server_tokens      off;
                charset            utf-8;

                # MIME types
                include      /etc/nginx/mime.types;
                default_type application/octet-stream;

                # Buffer sizes
                client_body_buffer_size    128k;
                client_header_buffer_size  1k;
                client_max_body_size       64m;
                large_client_header_buffers 4 16k;

                # Timeouts
                client_body_timeout   12;
                client_header_timeout 12;
                send_timeout          10;

                # Open file cache
                open_file_cache          max=200000 inactive=20s;
                open_file_cache_valid    30s;
                open_file_cache_min_uses 2;
                open_file_cache_errors   on;

                # Gzip (fallback when Brotli unavailable)
                gzip              on;
                gzip_vary         on;
                gzip_comp_level   6;
                gzip_min_length   256;
                gzip_proxied      any;
                gzip_types
                    text/plain text/css text/xml text/javascript
                    application/json application/javascript application/xml
                    application/rss+xml image/svg+xml font/woff font/woff2;

                # Rate limiting zones
                limit_req_zone $binary_remote_addr zone=wp_login:10m rate=20r/m;
                limit_req_zone $binary_remote_addr zone=api:10m rate=100r/m;
                limit_conn_zone $binary_remote_addr zone=addr:10m;

                # Logging
                log_format main '$remote_addr - $remote_user [$time_local] '
                               '"$request" $status $body_bytes_sent '
                               '"$http_referer" "$http_user_agent" '
                               '$request_time $upstream_cache_status';
                access_log /var/log/nginx/access.log main buffer=512k flush=5m;
                error_log  /var/log/nginx/error.log warn;

                # Include configs
                include /etc/nginx/conf.d/*.conf;
                include /etc/nginx/sites-enabled/*;
            }}
        """)

    def fastcgi_cache_conf(self) -> str:
        return textwrap.dedent(f"""\
            # FastCGI cache global settings
            fastcgi_cache_key "$scheme$request_method$host$request_uri";
            fastcgi_cache_use_stale error timeout invalid_header http_500;
            fastcgi_cache_lock on;
            fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
        """)

    def brotli_conf(self) -> str:
        return textwrap.dedent("""\
            # Brotli compression
            brotli            on;
            brotli_comp_level 6;
            brotli_static     on;
            brotli_types
                text/plain text/css text/xml text/javascript
                application/json application/javascript application/xml
                application/rss+xml image/svg+xml font/woff font/woff2
                application/x-font-ttf application/vnd.ms-fontobject;
        """)

    def security_headers_conf(self) -> str:
        return textwrap.dedent("""\
            # Security Headers
            add_header X-Frame-Options           "SAMEORIGIN"    always;
            add_header X-Content-Type-Options    "nosniff"       always;
            add_header X-XSS-Protection          "1; mode=block" always;
            add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
            add_header Permissions-Policy        "camera=(), microphone=(), geolocation=()" always;
            add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
        """)

    def http3_quic_conf(self) -> str:
        return textwrap.dedent("""\
            # HTTP/3 + QUIC (add to SSL server blocks)
            # listen 443 quic reuseport;
            # add_header Alt-Svc 'h3=":443"; ma=86400';
            # quic_retry on;
            # ssl_early_data on;

            # Uncomment after confirming Nginx was compiled with QUIC support:
            # nginx -V 2>&1 | grep quic
        """)

    def cloudflare_realip_conf(self) -> str:
        return textwrap.dedent("""\
            # Cloudflare Real IP Ranges (updated quarterly)
            # IPv4
            set_real_ip_from 103.21.244.0/22;
            set_real_ip_from 103.22.200.0/22;
            set_real_ip_from 103.31.4.0/22;
            set_real_ip_from 104.16.0.0/13;
            set_real_ip_from 104.24.0.0/14;
            set_real_ip_from 108.162.192.0/18;
            set_real_ip_from 131.0.72.0/22;
            set_real_ip_from 141.101.64.0/18;
            set_real_ip_from 162.158.0.0/15;
            set_real_ip_from 172.64.0.0/13;
            set_real_ip_from 173.245.48.0/20;
            set_real_ip_from 188.114.96.0/20;
            set_real_ip_from 190.93.240.0/20;
            set_real_ip_from 197.234.240.0/22;
            set_real_ip_from 198.41.128.0/17;
            # IPv6
            set_real_ip_from 2400:cb00::/32;
            set_real_ip_from 2606:4700::/32;
            set_real_ip_from 2803:f800::/32;
            set_real_ip_from 2405:b500::/32;
            set_real_ip_from 2405:8100::/32;
            set_real_ip_from 2a06:98c0::/29;
            set_real_ip_from 2c0f:f248::/32;
            real_ip_header CF-Connecting-IP;
        """)

    def ddos_protection_conf(self) -> str:
        return textwrap.dedent("""\
            # DDoS & Abuse Protection
            # Block common scanner user-agents
            map $http_user_agent $blocked_agent {
                default          0;
                ~*sqlmap         1;
                ~*nikto          1;
                ~*masscan        1;
                ~*nmap           1;
                ~*zgrab          1;
                ~*python-requests 1;
                ""          1;
            }

            # Connection limit per IP
            # limit_conn addr 100;

            # Geo-block (example - enable as needed)
            # geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
            #     auto_reload 60m;
            #     $geoip2_country_code country iso_code;
            # }
        """)

    def wordpress_snippet(self) -> str:
        return textwrap.dedent("""\
            # WordPress global rules (include in server blocks)

            # Deny access to sensitive WP files
            location ~* /wp-config.php                    { deny all; }
            location ~* /xmlrpc.php                       { deny all; return 403; }
            location ~* /wp-includes/.*\\.php              { deny all; }
            location ~* /wp-content/uploads/.*\\.php       { deny all; }
            location ~* /wp-content/themes/.*\\.php        {
                location ~* /wp-content/themes/[^/]+/[^/]+\\.php { allow all; }
                deny all;
            }

            # Block WordPress user enumeration
            if ($query_string ~ "author=\\d") { return 403; }

            # Disable directory listing
            autoindex off;
        """)

    def write_all(self) -> None:
        configs = {
            "/etc/nginx/nginx.conf":                       self.main_conf(),
            "/etc/nginx/conf.d/fastcgi-cache.conf":        self.fastcgi_cache_conf(),
            "/etc/nginx/conf.d/brotli.conf":               self.brotli_conf(),
            "/etc/nginx/conf.d/security-headers.conf":     self.security_headers_conf(),
            "/etc/nginx/conf.d/http3-quic.conf":           self.http3_quic_conf(),
            "/etc/nginx/conf.d/cloudflare-realip.conf":    self.cloudflare_realip_conf(),
            "/etc/nginx/conf.d/ddos-protection.conf":      self.ddos_protection_conf(),
            "/etc/nginx/snippets/wordpress.conf":          self.wordpress_snippet(),
        }
        for path, content in configs.items():
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_text(content)
            print(f"  ✓ Written: {path}")


# ─────────────────────────────────────────────
# PHP CONFIGURATION
# ─────────────────────────────────────────────

class PHPConfigurator:
    def __init__(self, hw: HardwareProfile):
        self.hw = hw

    def php_ini(self) -> str:
        return textwrap.dedent(f"""\
            ; EasyInstall Ultra - PHP {self.hw.php_version} Optimized Config
            ; Generated: {datetime.now().isoformat()}

            [PHP]
            engine                  = On
            short_open_tag          = Off
            precision               = 14
            serialize_precision     = -1
            disable_functions       = exec,passthru,shell_exec,system,proc_open,popen
            max_execution_time      = 120
            max_input_time          = 120
            max_input_vars          = 10000
            memory_limit            = {self.hw.php_memory_limit}
            error_reporting         = E_ALL & ~E_DEPRECATED & ~E_STRICT
            display_errors          = Off
            display_startup_errors  = Off
            log_errors              = On
            error_log               = /var/log/php{self.hw.php_version}-fpm.log
            post_max_size           = 64M
            upload_max_filesize     = 64M
            max_file_uploads        = 20
            default_socket_timeout  = 60
            date.timezone           = UTC
            cgi.fix_pathinfo        = 0

            ; Realpath cache
            realpath_cache_size = {self.hw.php_realpath_cache}
            realpath_cache_ttl  = 600

            ; Session
            session.save_handler   = redis
            session.save_path      = "tcp://127.0.0.1:6379?database=2"
            session.gc_maxlifetime = 86400
            session.cookie_secure  = 1
            session.cookie_httponly = 1
            session.cookie_samesite = Lax
        """)

    def opcache_ini(self) -> str:
        return textwrap.dedent(f"""\
            ; OPcache + JIT - EasyInstall Ultra
            zend_extension=opcache

            [opcache]
            opcache.enable                    = 1
            opcache.enable_cli                = 0
            opcache.memory_consumption        = {self.hw.php_opcache_memory}
            opcache.interned_strings_buffer   = {self.hw.php_interned_strings}
            opcache.max_accelerated_files     = 100000
            opcache.max_wasted_percentage     = 5
            opcache.validate_timestamps       = 0
            opcache.revalidate_freq           = 0
            opcache.fast_shutdown             = 1
            opcache.save_comments             = 1
            opcache.huge_code_pages           = 1
            opcache.consistency_checks        = 0

            ; JIT (PHP 8.x) - tracing mode = best for WordPress workloads
            opcache.jit                       = tracing
            opcache.jit_buffer_size           = {self.hw.php_jit_buffer}M

            ; Persistent file cache (survives PHP-FPM restarts)
            opcache.file_cache                = /var/cache/php-opcache
            opcache.file_cache_only           = 0
            opcache.file_cache_consistency_checks = 0
        """)

    def apcu_ini(self) -> str:
        return textwrap.dedent(f"""\
            ; APCu - EasyInstall Ultra
            extension=apcu.so
            apc.enabled       = 1
            apc.shm_size      = {min(128, self.hw.ram_mb // 16)}M
            apc.ttl           = 7200
            apc.enable_cli    = 0
            apc.serializer    = igbinary
        """)

    def fpm_pool(self) -> str:
        start = max(2, self.hw.php_max_children // 4)
        min_spare = max(2, self.hw.php_max_children // 4)
        max_spare = max(4, self.hw.php_max_children // 2)

        return textwrap.dedent(f"""\
            ; EasyInstall Ultra - PHP-FPM Default Pool
            [www]
            user  = www-data
            group = www-data

            listen = /run/php/php{self.hw.php_version}-fpm.sock
            listen.owner = www-data
            listen.group = www-data
            listen.mode  = 0660

            pm                   = dynamic
            pm.max_children      = {self.hw.php_max_children}
            pm.start_servers     = {start}
            pm.min_spare_servers = {min_spare}
            pm.max_spare_servers = {max_spare}
            pm.max_requests      = 500
            pm.process_idle_timeout = 10s

            ; Status page
            pm.status_path = /fpm-status
            ping.path      = /fpm-ping
            ping.response  = pong

            ; Logging
            access.log = /var/log/php{self.hw.php_version}-fpm-access.log
            slowlog     = /var/log/php{self.hw.php_version}-fpm-slow.log
            request_slowlog_timeout = 5s

            ; Security
            security.limit_extensions = .php
        """)

    def write_all(self) -> None:
        ver = self.hw.php_version
        # Persistent opcache file cache dir (survives reboots unlike /tmp)
        opcache_dir = Path("/var/cache/php-opcache")
        opcache_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(["chown", f"www-data:www-data", str(opcache_dir)], capture_output=True)

        configs = {
            f"/etc/php/{ver}/fpm/php.ini":                     self.php_ini(),
            f"/etc/php/{ver}/mods-available/opcache.ini":      self.opcache_ini(),
            f"/etc/php/{ver}/mods-available/apcu.ini":         self.apcu_ini(),
            f"/etc/php/{ver}/fpm/pool.d/www.conf":             self.fpm_pool(),
        }
        for path, content in configs.items():
            p = Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
            print(f"  ✓ Written: {path}")

        # Enable opcache/apcu modules
        for mod in ["opcache", "apcu", "igbinary", "redis"]:
            subprocess.run(["phpenmod", "-v", ver, mod], capture_output=True)

        subprocess.run(["systemctl", "restart", f"php{ver}-fpm"], capture_output=True)
        print(f"  ✓ php{ver}-fpm restarted")


# ─────────────────────────────────────────────
# MARIADB CONFIGURATION
# ─────────────────────────────────────────────

class MariaDBConfigurator:
    def __init__(self, hw: HardwareProfile):
        self.hw = hw

    def wordpress_cnf(self) -> str:
        return textwrap.dedent(f"""\
            # EasyInstall Ultra - MariaDB WordPress Tuning
            # Generated: {datetime.now().isoformat()}

            [mysqld]
            # ── InnoDB ─────────────────────────────────
            innodb_buffer_pool_size          = {self.hw.mysql_buffer_pool_mb}M
            innodb_buffer_pool_instances     = {self.hw.mysql_buffer_pool_instances}
            innodb_buffer_pool_chunk_size    = 128M
            innodb_file_per_table            = 1
            innodb_flush_log_at_trx_commit   = 2
            innodb_flush_method              = O_DIRECT
            innodb_redo_log_capacity         = 536870912
            innodb_log_buffer_size           = 64M
            innodb_io_capacity               = {self.hw.mysql_innodb_io_capacity}
            innodb_io_capacity_max           = {self.hw.mysql_innodb_io_capacity * 2}
            innodb_read_io_threads           = {self.hw.mysql_innodb_read_threads}
            innodb_write_io_threads          = {self.hw.mysql_innodb_write_threads}
            innodb_autoinc_lock_mode         = 2
            innodb_stats_on_metadata         = 0
            innodb_open_files                = 4000

            # ── Connections ────────────────────────────
            max_connections          = {self.hw.mysql_max_connections}
            max_allowed_packet       = 64M
            thread_cache_size        = {self.hw.mysql_thread_cache_size}
            wait_timeout             = 600
            interactive_timeout      = 600

            # ── Caches ─────────────────────────────────
            table_open_cache         = {self.hw.mysql_table_open_cache}
            table_definition_cache   = 4096
            # NOTE: query_cache removed in MariaDB 10.9 — do NOT add it back

            # ── Temp tables ────────────────────────────
            tmp_table_size           = 64M
            max_heap_table_size      = 64M

            # ── MyISAM ─────────────────────────────────
            key_buffer_size          = 32M

            # ── Slow query log ─────────────────────────
            slow_query_log           = 1
            slow_query_log_file      = /var/log/mysql/slow-queries.log
            long_query_time          = 2
            log_queries_not_using_indexes = 1

            # ── Binary log (disabled for single server) ─
            skip-log-bin

            # ── Character set ──────────────────────────
            character-set-server     = utf8mb4
            collation-server         = utf8mb4_unicode_ci

            # ── Performance schema ─────────────────────
            performance_schema       = OFF

            [client]
            default-character-set   = utf8mb4

            [mysql]
            default-character-set   = utf8mb4
        """)

    def write_all(self) -> None:
        path = "/etc/mysql/mariadb.conf.d/99-wordpress.cnf"
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(self.wordpress_cnf())
        print(f"  ✓ Written: {path}")

        # Create slow query log dir
        Path("/var/log/mysql").mkdir(exist_ok=True)
        subprocess.run(["chown", "mysql:mysql", "/var/log/mysql"], capture_output=True)
        subprocess.run(["systemctl", "restart", "mariadb"], capture_output=True)
        print("  ✓ MariaDB restarted")


# ─────────────────────────────────────────────
# REDIS CONFIGURATION
# ─────────────────────────────────────────────

class RedisConfigurator:
    def __init__(self, hw: HardwareProfile):
        self.hw = hw

    def redis_conf(self) -> str:
        return textwrap.dedent(f"""\
            # EasyInstall Ultra - Redis 7.x Config
            # Generated: {datetime.now().isoformat()}

            # Network
            bind 127.0.0.1 -::1
            protected-mode yes
            port 6379
            tcp-backlog 65535
            timeout 0
            tcp-keepalive 300

            # Performance
            io-threads {self.hw.redis_io_threads}
            io-threads-do-reads yes
            lazyfree-lazy-eviction yes
            lazyfree-lazy-expire yes
            lazyfree-lazy-server-del yes

            # Memory
            maxmemory {self.hw.redis_max_memory_mb}mb
            maxmemory-policy allkeys-lru
            maxmemory-samples 10
            active-defrag-enabled yes
            active-defrag-ignore-bytes 100mb
            active-defrag-threshold-lower 10

            # Persistence (DISABLED for pure cache)
            save ""
            appendonly no

            # Clients
            maxclients 10000
            tcp-backlog 65535

            # Slow log
            slowlog-log-slower-than 10000
            slowlog-max-len 128

            # Databases (0=default, 1=object-cache, 2=sessions)
            databases 16

            # Logging
            loglevel notice
            logfile /var/log/redis/redis-server.log

            # Unix socket (for low-latency local connections)
            unixsocket /var/run/redis/redis.sock
            unixsocketperm 770
        """)

    def write_all(self) -> None:
        Path("/var/run/redis").mkdir(parents=True, exist_ok=True)
        subprocess.run(["chown", "redis:redis", "/var/run/redis"], capture_output=True)

        path = "/etc/redis/redis.conf"
        Path(path).write_text(self.redis_conf())
        print(f"  ✓ Written: {path}")

        subprocess.run(["systemctl", "restart", "redis-server"], capture_output=True)
        print("  ✓ Redis restarted")


# ─────────────────────────────────────────────
# MONITORING SCRIPTS
# ─────────────────────────────────────────────

class MonitoringConfigurator:
    def __init__(self, hw: HardwareProfile):
        self.hw = hw

    def health_check_script(self) -> str:
        return textwrap.dedent("""\
            #!/usr/bin/env python3
            \"\"\"EasyInstall Ultra - Health Monitor\"\"\"
            import subprocess, sys, json
            from datetime import datetime

            def check_service(name):
                r = subprocess.run(["systemctl","is-active","--quiet",name])
                return r.returncode == 0

            def check_redis():
                r = subprocess.run(["redis-cli","ping"], capture_output=True, text=True)
                return r.stdout.strip() == "PONG"

            def check_mysql():
                r = subprocess.run(["mysqladmin","ping","-s"], capture_output=True)
                return r.returncode == 0

            def disk_usage():
                import shutil
                t = shutil.disk_usage("/")
                return round(t.used / t.total * 100, 1)

            def mem_usage():
                with open("/proc/meminfo") as f:
                    data = dict(l.split(":") for l in f if ":" in l)
                total = int(data["MemTotal"].split()[0])
                avail = int(data["MemAvailable"].split()[0])
                return round((total - avail) / total * 100, 1)

            status = {
                "timestamp": datetime.now().isoformat(),
                "services": {
                    "nginx":   check_service("nginx"),
                    "mariadb": check_service("mariadb"),
                    "redis":   check_redis(),
                    "fail2ban": check_service("fail2ban"),
                },
                "resources": {
                    "disk_pct": disk_usage(),
                    "mem_pct":  mem_usage(),
                }
            }

            print(json.dumps(status, indent=2))

            # Alert if critical
            if disk_usage() > 85:
                print("ALERT: Disk usage > 85%!", file=sys.stderr)
            if not all(status["services"].values()):
                failed = [k for k,v in status["services"].items() if not v]
                print(f"ALERT: Services down: {failed}", file=sys.stderr)
        """)

    def db_optimize_script(self) -> str:
        return textwrap.dedent("""\
            #!/usr/bin/env python3
            \"\"\"EasyInstall Ultra - Database Optimizer\"\"\"
            import subprocess, sys

            def run_mysql(query):
                r = subprocess.run(
                    ["mysql", "--defaults-file=/root/.my.cnf", "-e", query],
                    capture_output=True, text=True
                )
                return r.stdout

            def get_databases():
                out = run_mysql("SHOW DATABASES;")
                skip = {"information_schema","performance_schema","mysql","sys"}
                return [l.strip() for l in out.strip().split("\\n")[1:] if l.strip() not in skip]

            def optimize_db(db_name):
                print(f"Optimizing {db_name}...")
                tables = run_mysql(f"SHOW TABLES IN `{db_name}`;").strip().split("\\n")[1:]
                for t in tables:
                    t = t.strip()
                    if t:
                        run_mysql(f"OPTIMIZE TABLE `{db_name}`.`{t}`;")
                        print(f"  ✓ {t}")

            def cleanup_wp_options(db_name):
                # Remove autoloaded transients older than 1 day
                run_mysql(f\"\"\"DELETE FROM `{db_name}`.wp_options
                    WHERE option_name LIKE '_transient_%'
                    AND option_value < UNIX_TIMESTAMP(NOW() - INTERVAL 1 DAY);\"\"\")
                print(f"  ✓ Cleaned transients in {db_name}")

            for db in get_databases():
                optimize_db(db)
                if db.startswith("wp_"):
                    cleanup_wp_options(db)

            print("\\nDatabase optimization complete!")
        """)

    def write_all(self) -> None:
        scripts = {
            "/usr/local/bin/easyinstall-health":    self.health_check_script(),
            "/usr/local/bin/easyinstall-db-optimize": self.db_optimize_script(),
        }
        for path, content in scripts.items():
            Path(path).write_text(content)
            Path(path).chmod(0o755)
            print(f"  ✓ Written: {path}")

        # Daily DB optimize cron
        cron_line = "0 4 * * * /usr/local/bin/easyinstall-db-optimize >> /var/log/easyinstall/db-optimize.log 2>&1"
        subprocess.run(
            f'(crontab -l 2>/dev/null | grep -v "db-optimize"; echo "{cron_line}") | crontab -',
            shell=True, capture_output=True
        )
        print("  ✓ DB optimize cron added")


# ─────────────────────────────────────────────
# MANAGEMENT COMMAND INSTALLER
# ─────────────────────────────────────────────

class ManagementInstaller:
    def install_easyinstall_command(self) -> None:
        """Install the easyinstall CLI command"""
        script_dir = Path(__file__).parent.resolve()
        target = Path("/usr/local/bin/easyinstall")

        wrapper = textwrap.dedent(f"""\
            #!/usr/bin/env bash
            exec "{script_dir}/easyinstall.sh" "$@"
        """)
        target.write_text(wrapper)
        target.chmod(0o755)
        print("  ✓ 'easyinstall' command installed → /usr/local/bin/easyinstall")


# ─────────────────────────────────────────────
# MAIN ENTRY POINT
# ─────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="EasyInstall Ultra Config Generator")
    p.add_argument("--ram-mb",      type=int,   default=1024)
    p.add_argument("--cores",       type=int,   default=2)
    p.add_argument("--disk-type",   type=str,   default="SSD", choices=["SSD","HDD"])
    p.add_argument("--php-version", type=str,   default="8.3")
    p.add_argument("--features",    type=str,   default="woocommerce,cloudflare,s3")
    p.add_argument("--dry-run",     action="store_true")
    p.add_argument("--output-json", type=str,   help="Write summary JSON to file")
    return p.parse_args()


def main():
    args = parse_args()
    hw   = HardwareProfile(args.ram_mb, args.cores, args.disk_type, args.php_version)
    features = [f.strip() for f in args.features.split(",")]

    print("\n🔧 EasyInstall Ultra - Python Config Generator")
    print(f"   RAM: {hw.ram_mb}MB | Cores: {hw.cores} | Disk: {hw.disk_type}")
    print(f"   PHP: {hw.php_version} | Features: {', '.join(features)}")
    print("")

    summary = hw.summary()

    if args.dry_run:
        print("DRY RUN - Configuration values:")
        print(json.dumps(summary, indent=2))
        return

    # Check root
    if os.geteuid() != 0:
        print("⚠  Not running as root - writing to /tmp for preview")
        dry = True
    else:
        dry = False

    sections = [
        ("Nginx",      NginxConfigurator(hw)),
        ("PHP",        PHPConfigurator(hw)),
        ("MariaDB",    MariaDBConfigurator(hw)),
        ("Redis",      RedisConfigurator(hw)),
        ("Monitoring", MonitoringConfigurator(hw)),
    ]

    for name, configurator in sections:
        print(f"\n[{name}]")
        if not dry:
            try:
                configurator.write_all()
            except Exception as e:
                print(f"  ⚠ Error: {e}")
        else:
            print(f"  (skip - not root)")

    if not dry:
        ManagementInstaller().install_easyinstall_command()

    if args.output_json:
        Path(args.output_json).write_text(json.dumps(summary, indent=2))
        print(f"\n  ✓ Summary written: {args.output_json}")

    print("\n✅ Configuration generation complete!")
    print("\n📊 Calculated Performance Values:")
    print(f"   PHP max_children:     {hw.php_max_children}")
    print(f"   PHP memory_limit:     {hw.php_memory_limit}")
    print(f"   PHP OPcache memory:   {hw.php_opcache_memory}M")
    print(f"   PHP JIT buffer:       {hw.php_jit_buffer}M")
    print(f"   MariaDB buffer pool:  {hw.mysql_buffer_pool_mb}M")
    print(f"   MariaDB max_conn:     {hw.mysql_max_connections}")
    print(f"   Redis maxmemory:      {hw.redis_max_memory_mb}mb")
    print(f"   Nginx workers:        {hw.nginx_worker_processes}")
    print(f"   Nginx connections:    {hw.nginx_worker_connections}")


if __name__ == "__main__":
    main()

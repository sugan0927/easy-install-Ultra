# EasyInstall Ultra — Troubleshooting Guide

## Quick Diagnosis

```bash
# Check all services at once
easyinstall health

# View recent install log
tail -100 /var/log/easyinstall/install-*.log | tail -100

# Check system resources
easyinstall status
```

---

## Common Issues

### 1. 502 Bad Gateway

**Cause:** PHP-FPM is down or the socket path is wrong.

```bash
# Check PHP-FPM status
systemctl status php8.3-fpm

# Check socket exists
ls -la /run/php/php8.3-fpm-*.sock

# Restart PHP-FPM
systemctl restart php8.3-fpm

# Check Nginx error log
tail -50 /var/log/nginx/error.log

# Check site error log
tail -50 /var/www/example.com/logs/error.log
```

**Fix — socket mismatch:**
```bash
# Verify Nginx site config socket path matches FPM pool
grep "fastcgi_pass" /etc/nginx/sites-available/example.com
grep "^listen" /etc/php/8.3/fpm/pool.d/example_com.conf
# Both should match: /run/php/php8.3-fpm-example.com.sock
```

---

### 2. 504 Gateway Timeout

**Cause:** PHP request taking too long.

```bash
# Check slow log
tail -50 /var/www/example.com/logs/php-slow.log

# Increase timeouts in Nginx site config
# fastcgi_read_timeout 300;

# Increase PHP max_execution_time in FPM pool
# php_admin_value[max_execution_time] = 300
systemctl reload php8.3-fpm
```

---

### 3. WordPress Not Installing / "Error establishing database connection"

```bash
# Test MySQL connection
mysql -u wp_user -p'password' -e "SHOW DATABASES;"

# Verify wp-config.php credentials
grep -E "DB_NAME|DB_USER|DB_PASSWORD|DB_HOST" /var/www/example.com/public/wp-config.php

# Check MariaDB is running
systemctl status mariadb

# Check MariaDB error log
tail -30 /var/log/mysql/error.log

# Reset root password if needed
systemctl stop mariadb
mysqld_safe --skip-grant-tables &
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'newpass'; FLUSH PRIVILEGES;"
```

---

### 4. Redis Connection Failed

```bash
# Test Redis
redis-cli ping
# Expected: PONG

# Check Redis is running
systemctl status redis-server

# Check Redis log
tail -30 /var/log/redis/redis-server.log

# Check socket permissions
ls -la /var/run/redis/redis.sock
# www-data must be in the redis group

# Add www-data to redis group
usermod -aG redis www-data
systemctl restart php8.3-fpm
```

---

### 5. SSL Certificate Fails

```bash
# Verify DNS is pointing to this server
dig +short example.com
curl -I http://example.com  # Should get response (not timeout)

# Check port 80 is open
ufw status | grep "80"
curl -I http://example.com/.well-known/acme-challenge/test

# Run certbot manually with verbose
certbot --nginx -d example.com -d www.example.com --dry-run

# Check certbot logs
tail -50 /var/log/letsencrypt/letsencrypt.log
```

---

### 6. Nginx Won't Start / Config Error

```bash
# Test config syntax
nginx -t

# View full error
nginx -T 2>&1 | grep -A5 "error"

# Common fix: duplicate server_name
grep -r "server_name" /etc/nginx/sites-enabled/

# Check for port conflicts
ss -tlnp | grep ':80\|:443'

# Check Nginx error log
journalctl -u nginx -n 50
```

---

### 7. Cache Not Working (Always Dynamic)

```bash
# Check cache header
curl -sI http://example.com/ | grep "X-FastCGI-Cache"
# Should show: HIT or MISS (not absent)

# If absent: FastCGI cache zone not matched
grep -r "fastcgi_cache " /etc/nginx/sites-enabled/example.com

# Check cache directory exists
ls -la /var/run/nginx-cache/example.com/

# Recreate if missing
mkdir -p /var/run/nginx-cache/example.com
chown www-data:www-data /var/run/nginx-cache/example.com
systemctl reload nginx
```

---

### 8. High RAM Usage

```bash
# Check what's using RAM
ps aux --sort=-%mem | head -20

# Check PHP-FPM workers
ps --no-headers -o "pid,rss,cmd" -C php-fpm8.3 | awk '{sum+=$2; count++} END {print count" workers, avg "sum/count/1024"MB each"}'

# Reduce max_children if RAM is tight
nano /etc/php/8.3/fpm/pool.d/example_com.conf
# Lower pm.max_children
systemctl reload php8.3-fpm

# Check Redis memory
redis-cli info memory | grep used_memory_human
```

---

### 9. WordPress Admin Slow (Cache Not Bypassing)

wp-admin should bypass FastCGI cache automatically. If it's still slow:

```bash
# Verify bypass rule in Nginx config
grep "wp-admin" /etc/nginx/sites-available/example.com

# Expected:
# if ($request_uri ~* "/wp-admin/") { set $skip_cache 1; }

# Check OPcache for admin
php8.3 -r "var_dump(opcache_get_status()['opcache_enabled']);"
```

---

### 10. Fail2ban Blocking Legitimate Users

```bash
# Check banned IPs
fail2ban-client status wordpress-login
fail2ban-client status nginx-http-auth

# Unban an IP
fail2ban-client set wordpress-login unbanip 1.2.3.4

# Add whitelist in /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 YOUR_OFFICE_IP
```

---

### 11. Disk Full

```bash
# Check disk usage
df -h
du -sh /var/www/* | sort -rh | head -20

# Clean old backups
find /var/backups/easyinstall -name "*.tar.gz" -mtime +7 -delete

# Clean Nginx cache
easyinstall purge-cache

# Clean old logs
find /var/log -name "*.gz" -mtime +30 -delete
journalctl --vacuum-time=30d

# Clean APT cache
apt-get clean
```

---

### 12. PHP Memory Exhausted

```
Fatal error: Allowed memory size of 134217728 bytes exhausted
```

```bash
# Increase for specific site
nano /etc/php/8.3/fpm/pool.d/example_com.conf
# php_admin_value[memory_limit] = 512M
systemctl reload php8.3-fpm

# Or globally
nano /etc/php/8.3/fpm/php.ini
# memory_limit = 512M
```

---

## Logs Reference

| Log File | Purpose |
|----------|---------|
| `/var/log/easyinstall/install-*.log` | Installation log |
| `/var/log/nginx/error.log` | Nginx errors |
| `/var/www/DOMAIN/logs/error.log` | Site-specific errors |
| `/var/www/DOMAIN/logs/php-error.log` | PHP errors for site |
| `/var/www/DOMAIN/logs/php-slow.log` | Slow PHP requests |
| `/var/log/mysql/error.log` | MariaDB errors |
| `/var/log/mysql/slow-queries.log` | Slow DB queries |
| `/var/log/redis/redis-server.log` | Redis log |
| `/var/log/fail2ban.log` | Fail2ban bans |
| `/var/log/letsencrypt/letsencrypt.log` | SSL cert logs |

---

## Getting Help

1. Run `easyinstall health` for a quick system check
2. Check the relevant log file from the table above
3. Search closed issues on GitHub
4. Open an issue with: OS version, `easyinstall health` output, and relevant log excerpts

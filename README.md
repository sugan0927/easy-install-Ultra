# ⚡ EasyInstall Ultra

> **World's Fastest WordPress Optimizer** — Sub-50ms TTFB, Auto-tuned, Production-Ready

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PHP](https://img.shields.io/badge/PHP-8.3-blue.svg)](https://php.net)
[![Nginx](https://img.shields.io/badge/Nginx-mainline-green.svg)](https://nginx.org)
[![MariaDB](https://img.shields.io/badge/MariaDB-11.4-orange.svg)](https://mariadb.org)
[![Redis](https://img.shields.io/badge/Redis-7.x-red.svg)](https://redis.io)

---

## 🚀 One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/youruser/EasyInstall-Ultra/main/install.sh | sudo bash
sudo easyinstall install
```

---

## 📊 Performance Benchmarks

| Metric | Default WordPress | EasyInstall Ultra | Improvement |
|--------|:-----------------:|:-----------------:|:-----------:|
| TTFB | ~800ms | **< 50ms** | **16x faster** |
| LCP | ~4.5s | **< 1.5s** | **3x faster** |
| Requests/sec | ~50 | **5,000+** | **100x more** |
| Concurrent Users | ~20 | **2,000+** | **100x more** |
| Cache Hit Rate | 0% | **95%+** | ∞ |
| DB Queries/sec | ~200 | **2,000+** | **10x more** |
| Memory Usage | ~400MB | **~120MB** | **3.3x less** |

> Benchmarks on 2 vCPU / 4GB RAM VPS (Hetzner CX21). Results vary by server and traffic pattern.

---

## ✨ Features

### 🏎 Performance Stack
- **Nginx** mainline with Brotli compression + FastCGI microcaching
- **PHP 8.3** with OPcache JIT (tracing mode) + APCu
- **MariaDB 11.4** with InnoDB buffer pool auto-tuned to RAM
- **Redis 7.x** object cache with igbinary serializer (no persistence)
- **TCP BBR** congestion control for faster network throughput
- **HTTP/3 + QUIC** ready (enable in config)

### 🔒 Security
- UFW firewall (rate-limited SSH, HTTP/HTTPS/UDP-QUIC only)
- Fail2ban with WordPress-specific login protection
- Nginx security headers (HSTS, X-Frame, CSP, etc.)
- PHP execution blocked in `uploads/`
- XML-RPC disabled
- User enumeration blocked

### ☁️ Cloud Integrations
- **Cloudflare** Real IP detection + CDN-aware cache bypass
- **S3 / AWS** compatible remote backup support
- Auto cloud provider detection (AWS, DO, Hetzner, GCP, Linode, Vultr)

### 🛒 WooCommerce Optimized
- Cart/Checkout/My-Account cache bypass
- Extended PHP timeouts for order processing
- Session isolation via Redis

### 🔧 Zero-Configuration Auto-Tuning
```
RAM: 512MB    → PHP max_children: 8   | InnoDB: 256MB | Redis: 128MB
RAM: 1GB      → PHP max_children: 16  | InnoDB: 512MB | Redis: 256MB
RAM: 2GB      → PHP max_children: 32  | InnoDB: 1GB   | Redis: 512MB
RAM: 4GB      → PHP max_children: 64  | InnoDB: 2GB   | Redis: 1GB
RAM: 8GB+     → PHP max_children: 128 | InnoDB: 2GB   | Redis: 2GB
```

---

## 📋 Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Ubuntu 22.04 / Debian 11 | Ubuntu 24.04 / Debian 12 |
| RAM | 512 MB | 2 GB+ |
| CPU | 1 core | 2+ cores |
| Disk | 10 GB SSD | 40 GB NVMe SSD |
| Root access | Required | Required |

---

## 🛠 Usage

### Full Installation
```bash
sudo easyinstall install
```

### Create WordPress Site
```bash
# Basic
sudo easyinstall create example.com

# With SSL
sudo easyinstall create example.com --ssl

# With WooCommerce optimization
sudo easyinstall create shop.example.com --ssl --woocommerce

# Specific PHP version
sudo easyinstall create example.com --php=8.4 --ssl
```

### SSL Management
```bash
sudo easyinstall ssl example.com          # Get/install certificate
sudo easyinstall ssl-renew                # Renew all certificates
```

### Backup
```bash
sudo easyinstall backup daily example.com          # Daily backup
sudo easyinstall backup weekly example.com         # Weekly backup
sudo easyinstall s3-setup example.com my-bucket ACCESS_KEY SECRET_KEY
sudo easyinstall restore example.com /path/to/backup.tar.gz
```

### Performance
```bash
sudo easyinstall optimize                          # Re-tune all configs
sudo easyinstall warm-cache example.com            # Warm FastCGI cache
sudo easyinstall purge-cache example.com           # Purge site cache
sudo easyinstall benchmark example.com             # Run benchmark
```

### Monitoring
```bash
sudo easyinstall status                            # System overview
sudo easyinstall health                            # Health check
sudo easyinstall logs example.com                  # Tail site logs
sudo easyinstall redis-status                      # Redis info
```

### PHP
```bash
sudo easyinstall php-switch example.com 8.4        # Switch PHP version
sudo easyinstall php-status                        # Show installed PHP versions
```

### Site Management
```bash
sudo easyinstall list                              # List all sites
sudo easyinstall info example.com                  # Site details
sudo easyinstall delete example.com                # Delete site
```

---

## 🏗 Architecture

```
┌────────────────────────────────────────────────────────────┐
│                      Client Request                         │
└───────────────────────────┬────────────────────────────────┘
                            │
                    ┌───────▼────────┐
                    │   Cloudflare   │  CDN + DDoS Protection
                    │   (optional)   │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │     UFW        │  Firewall
                    │   Fail2ban     │  Intrusion Prevention
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │     Nginx      │  HTTP/2 + Brotli + Gzip
                    │   Mainline     │  FastCGI Microcache
                    └──┬─────────┬──┘
           Cache HIT   │         │  Cache MISS
                       │         │
              ┌────────▼──┐   ┌──▼──────────┐
              │  FastCGI  │   │  PHP 8.3    │  OPcache JIT
              │  Cache    │   │  FPM Pool   │  APCu
              └───────────┘   └──────┬──────┘
                                     │
                             ┌───────▼──────┐
                             │    Redis     │  Object Cache
                             │    7.x       │  Sessions
                             └──────┬───────┘
                                    │
                             ┌──────▼───────┐
                             │   MariaDB    │  InnoDB Buffer Pool
                             │    11.4      │  Query Cache
                             └──────────────┘
```

---

## 📁 File Structure

```
EasyInstall-Ultra/
├── easyinstall.sh          # Main Bash installer & CLI (~600 lines)
├── config.py               # Python config generator (~400 lines)
├── install.sh              # One-liner bootstrap
├── README.md               # This file
├── LICENSE                 # MIT License
├── .github/
│   └── workflows/
│       └── test.yml        # CI/CD pipeline
├── benchmarks/
│   └── results.md          # Benchmark data
└── docs/
    ├── performance-tuning.md
    ├── troubleshooting.md
    └── api.md
```

---

## ⚙️ Configuration Locations

After installation, configs are at:

| Component | Config File |
|-----------|-------------|
| Nginx | `/etc/nginx/nginx.conf` |
| PHP-FPM | `/etc/php/8.3/fpm/php.ini` |
| OPcache | `/etc/php/8.3/mods-available/opcache.ini` |
| MariaDB | `/etc/mysql/mariadb.conf.d/99-wordpress.cnf` |
| Redis | `/etc/redis/redis.conf` |
| Kernel | `/etc/sysctl.d/99-wordpress.conf` |
| Fail2ban | `/etc/fail2ban/jail.local` |
| Site configs | `/etc/easyinstall/sites/` |

---

## 🔄 Backup Strategy

EasyInstall Ultra uses a 3-tier backup rotation:

| Type | Schedule | Retention | Storage |
|------|----------|-----------|---------|
| Daily | 2:00 AM | 7 days | Local |
| Weekly | Sunday 3:00 AM | 30 days | Local + S3 |
| Monthly | 1st of month | 365 days | S3 |

---

## 🌐 Cloudflare Integration

```bash
# Cloudflare Real IP is auto-configured at:
# /etc/nginx/conf.d/cloudflare-realip.conf

# To enable Full (Strict) SSL mode:
# 1. Set SSL/TLS mode to "Full (Strict)" in Cloudflare dashboard
# 2. Run: easyinstall ssl your-domain.com
# 3. Enable HSTS in Cloudflare
```

---

## 💡 WooCommerce Tuning

EasyInstall Ultra automatically:
- Bypasses FastCGI cache for cart/checkout/account pages
- Sets cookie-based cache bypass for logged-in customers
- Extends PHP timeouts to 300s for order processing
- Stores WooCommerce sessions in Redis

---

## ❓ FAQ

**Q: Does this work with existing WordPress sites?**
A: Yes! Install first, then `easyinstall create` will set up the stack. Migrate your existing files to `/var/www/domain.com/public/`.

**Q: Can I use it with Cloudflare?**
A: Yes, Real IP detection is built-in. See `/etc/nginx/conf.d/cloudflare-realip.conf`.

**Q: How do I add more sites?**
A: `easyinstall create newsite.com --ssl` — each site gets its own PHP-FPM pool and FastCGI cache.

**Q: Is HTTP/3 supported?**
A: Config is generated and commented out. Enable it if your Nginx build includes QUIC support.

**Q: What PHP versions are supported?**
A: PHP 8.2, 8.3, and 8.4 can all be installed. Default is 8.3.

---

## 📄 License

MIT License — see [LICENSE](LICENSE)

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-optimization`
3. Commit: `git commit -m 'Add amazing optimization'`
4. Push: `git push origin feature/amazing-optimization`
5. Open a Pull Request

---

<p align="center">Made with ⚡ for high-performance WordPress hosting</p>

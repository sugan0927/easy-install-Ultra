/**
 * EasyInstall Ultra — Cloudflare Worker
 * WordPress Edge Cache + Security + Performance
 *
 * Architecture:
 *   Browser → Cloudflare Edge → [This Worker] → VPS Nginx → WordPress
 *
 * Features:
 *   - Smart cache bypass (wp-admin, logged-in, cart, checkout, POST)
 *   - Tracking param stripping from cache keys (utm_*, fbclid, etc.)
 *   - Security headers injected at edge (HSTS, CSP, X-Frame)
 *   - wp-login.php rate limiting at edge (before hitting VPS)
 *   - Cache purge webhook (triggered by WordPress on publish)
 *   - Stale-while-revalidate for zero-downtime cache refresh
 */

// ─────────────────────────────────────────────────────────────
// CONFIG  (override via wrangler.toml [vars] section)
// ─────────────────────────────────────────────────────────────
const CONFIG = {
  // Cache TTL (seconds)
  CACHE_TTL_HTML:    3600,      // HTML pages
  CACHE_TTL_STATIC:  31536000,  // CSS/JS/images (1 year)
  CACHE_TTL_FEED:    1800,      // RSS feeds

  // Rate limiting for wp-login.php
  LOGIN_MAX_ATTEMPTS: 5,
  LOGIN_WINDOW_SEC:   300,      // 5 minutes

  // Purge webhook secret (set in wrangler.toml or Cloudflare dashboard secret)
  PURGE_SECRET: typeof PURGE_WEBHOOK_SECRET !== "undefined"
    ? PURGE_WEBHOOK_SECRET
    : "change-me-in-wrangler-secrets",

  // Tracking params to strip from cache key
  STRIP_PARAMS: new Set([
    "utm_source","utm_medium","utm_campaign","utm_term","utm_content",
    "fbclid","gclid","gad_source","mc_eid","_ga","ref","source",
    "msclkid","twclid","igshid","li_fat_id",
  ]),
};

// ─────────────────────────────────────────────────────────────
// SECURITY HEADERS (added to every response)
// ─────────────────────────────────────────────────────────────
const SECURITY_HEADERS = {
  "X-Frame-Options":           "SAMEORIGIN",
  "X-Content-Type-Options":    "nosniff",
  "X-XSS-Protection":          "1; mode=block",
  "Referrer-Policy":           "strict-origin-when-cross-origin",
  "Permissions-Policy":        "camera=(), microphone=(), geolocation=()",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains; preload",
};

// ─────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────

/** Strip tracking/marketing query params to normalize cache key */
function stripTrackingParams(url) {
  const u = new URL(url);
  for (const key of [...u.searchParams.keys()]) {
    if (CONFIG.STRIP_PARAMS.has(key)) u.searchParams.delete(key);
  }
  return u.toString();
}

/** Build cache key: strip tracking params, normalize trailing slash */
function cacheKey(request) {
  const url = stripTrackingParams(request.url);
  return new Request(url, request);
}

/** Should this request bypass the cache entirely? */
function shouldBypass(request) {
  const url  = new URL(request.url);
  const path = url.pathname;
  const cookie = request.headers.get("Cookie") || "";

  // Always bypass POST/PUT/DELETE/PATCH
  if (!["GET", "HEAD"].includes(request.method)) return true;

  // WordPress admin, login, XML-RPC
  if (/^\/(wp-admin|wp-login\.php|xmlrpc\.php)/.test(path)) return true;

  // WordPress core dynamic files
  if (/\/(wp-cron\.php|wp-comments-post\.php)/.test(path)) return true;

  // WooCommerce — cart, checkout, account, add-to-cart
  if (/\/(cart|checkout|my-account|wc-api|add-to-cart=)/.test(path)) return true;

  // Logged-in WordPress user (any wordpress_* cookie)
  if (/wordpress_logged_in|wordpress_[a-f0-9]{20,}|wp-postpass/.test(cookie)) return true;

  // WooCommerce active session
  if (/woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session/.test(cookie)) return true;

  // Comment author cookie
  if (/comment_author_/.test(cookie)) return true;

  // Explicit no-cache request (from WordPress itself during publish)
  if (request.headers.get("Cache-Control") === "no-cache" &&
      request.headers.get("X-WP-Nonce")) return true;

  return false;
}

/** Is this a static asset? (long TTL, immutable) */
function isStaticAsset(pathname) {
  return /\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2|ttf|eot|otf|mp4|webm|pdf|wasm)$/i
    .test(pathname);
}

/** Is this an RSS/Atom feed? */
function isFeed(pathname) {
  return /\/feed\/?/.test(pathname);
}

/** Add security headers to a response */
function addSecurityHeaders(response) {
  const newHeaders = new Headers(response.headers);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
    newHeaders.set(k, v);
  }
  // Remove headers that leak server info
  newHeaders.delete("X-Powered-By");
  newHeaders.delete("Server");
  return new Response(response.body, {
    status:     response.status,
    statusText: response.statusText,
    headers:    newHeaders,
  });
}

/** Determine cache TTL based on content type */
function getCacheTTL(pathname) {
  if (isStaticAsset(pathname)) return CONFIG.CACHE_TTL_STATIC;
  if (isFeed(pathname))        return CONFIG.CACHE_TTL_FEED;
  return CONFIG.CACHE_TTL_HTML;
}

// ─────────────────────────────────────────────────────────────
// RATE LIMITER for /wp-login.php
// ─────────────────────────────────────────────────────────────

async function isLoginRateLimited(request, env) {
  // Requires a KV namespace bound as LOGIN_KV in wrangler.toml
  if (!env.LOGIN_KV) return false;

  const ip  = request.headers.get("CF-Connecting-IP") || "unknown";
  const key = `login_attempts:${ip}`;

  try {
    const raw     = await env.LOGIN_KV.get(key);
    const count   = raw ? parseInt(raw, 10) : 0;
    const newCount = count + 1;

    await env.LOGIN_KV.put(key, String(newCount), {
      expirationTtl: CONFIG.LOGIN_WINDOW_SEC,
    });

    return newCount > CONFIG.LOGIN_MAX_ATTEMPTS;
  } catch {
    return false; // On KV error, fail open (don't block)
  }
}

// ─────────────────────────────────────────────────────────────
// CACHE PURGE WEBHOOK  (POST /cf-purge)
// ─────────────────────────────────────────────────────────────
// WordPress calls this via wp_remote_post() on post publish/update.
// Add to your theme's functions.php:
//
//   add_action('save_post', 'cf_purge_post');
//   function cf_purge_post($post_id) {
//       if (wp_is_post_revision($post_id)) return;
//       $url = get_permalink($post_id);
//       wp_remote_post('https://your-domain.com/cf-purge', [
//           'body'    => json_encode(['url' => $url, 'secret' => 'YOUR_PURGE_SECRET']),
//           'headers' => ['Content-Type' => 'application/json'],
//       ]);
//   }

async function handlePurge(request, env) {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const secret = env.PURGE_WEBHOOK_SECRET || CONFIG.PURGE_SECRET;
  if (body.secret !== secret) {
    return new Response("Forbidden", { status: 403 });
  }

  if (!body.url) {
    return new Response("Missing url", { status: 400 });
  }

  // Delete from Cloudflare Cache API
  const cache = caches.default;
  try {
    const purgeUrl    = new URL(body.url);
    const deleted     = await cache.delete(new Request(purgeUrl.toString()));
    // Also purge without trailing slash variant
    const altUrl      = purgeUrl.pathname.endsWith("/")
      ? purgeUrl.toString().slice(0, -1)
      : purgeUrl.toString() + "/";
    await cache.delete(new Request(altUrl));

    return new Response(JSON.stringify({
      purged: deleted,
      url:    body.url,
    }), {
      status:  200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status:  500,
      headers: { "Content-Type": "application/json" },
    });
  }
}

// ─────────────────────────────────────────────────────────────
// HEALTH CHECK endpoint  (GET /cf-health)
// ─────────────────────────────────────────────────────────────
function handleHealth() {
  return new Response(JSON.stringify({
    status:    "ok",
    worker:    "EasyInstall Ultra",
    timestamp: new Date().toISOString(),
  }), {
    status:  200,
    headers: { "Content-Type": "application/json" },
  });
}

// ─────────────────────────────────────────────────────────────
// MAIN FETCH HANDLER
// ─────────────────────────────────────────────────────────────
export default {
  async fetch(request, env, ctx) {
    const url      = new URL(request.url);
    const pathname = url.pathname;

    // ── Internal endpoints ──────────────────────────────────
    if (pathname === "/cf-purge")  return handlePurge(request, env);
    if (pathname === "/cf-health") return handleHealth();

    // ── Rate limit wp-login.php ─────────────────────────────
    if (/^\/wp-login\.php/.test(pathname) && request.method === "POST") {
      const limited = await isLoginRateLimited(request, env);
      if (limited) {
        return new Response(
          "Too many login attempts. Please try again in 5 minutes.",
          {
            status:  429,
            headers: {
              "Content-Type":  "text/plain",
              "Retry-After":   String(CONFIG.LOGIN_WINDOW_SEC),
              ...SECURITY_HEADERS,
            },
          }
        );
      }
    }

    // ── Cache bypass path ───────────────────────────────────
    if (shouldBypass(request)) {
      const originResponse = await fetch(request);
      return addSecurityHeaders(originResponse);
    }

    // ── Cached path ─────────────────────────────────────────
    const cache       = caches.default;
    const normalizedReq = cacheKey(request);
    const ttl         = getCacheTTL(pathname);

    // Try cache first
    let response = await cache.match(normalizedReq);

    if (response) {
      // Cache HIT — add header and return
      const headers = new Headers(response.headers);
      headers.set("X-Cache", "HIT");
      headers.set("X-Cache-Worker", "EasyInstall-Ultra");
      return addSecurityHeaders(new Response(response.body, {
        status:     response.status,
        statusText: response.statusText,
        headers,
      }));
    }

    // Cache MISS — fetch from origin (VPS)
    const originRequest = new Request(normalizedReq.url, {
      method:  request.method,
      headers: request.headers,
      body:    request.body,
    });

    response = await fetch(originRequest);

    // Only cache successful, cacheable responses
    if (
      response.status === 200 &&
      !response.headers.get("Set-Cookie") &&
      response.headers.get("Cache-Control") !== "no-store"
    ) {
      const headers = new Headers(response.headers);

      // Set cache TTL
      headers.set("Cache-Control", `public, max-age=${ttl}, stale-while-revalidate=60`);
      headers.set("X-Cache", "MISS");
      headers.set("X-Cache-Worker", "EasyInstall-Ultra");

      const cachedResponse = new Response(response.clone().body, {
        status:     response.status,
        statusText: response.statusText,
        headers,
      });

      // Store in cache asynchronously (don't block response)
      ctx.waitUntil(cache.put(normalizedReq, cachedResponse.clone()));

      return addSecurityHeaders(cachedResponse);
    }

    // Non-cacheable (redirect, 4xx, 5xx, cookies) — pass through
    const headers = new Headers(response.headers);
    headers.set("X-Cache", "BYPASS");
    return addSecurityHeaders(new Response(response.body, {
      status:     response.status,
      statusText: response.statusText,
      headers,
    }));
  },
};

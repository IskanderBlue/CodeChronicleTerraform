data "cloudflare_zone" "this" {
  filter = {
    name = var.domain
  }
}

resource "cloudflare_dns_record" "app" {
  for_each = toset(var.subdomains)

  zone_id = data.cloudflare_zone.this.id
  name    = "${each.value}.${var.domain}"
  content = var.public_ip
  type    = "A"
  proxied = true
  ttl     = 1
}

# Preserve the pre-existing single (app) record when adopting for_each, so it
# is re-keyed in state rather than destroyed and recreated.
moved {
  from = cloudflare_dns_record.app
  to   = cloudflare_dns_record.app["app"]
}

# TLS mode is set to Full (strict) manually in the Cloudflare dashboard.
# The free plan does not support changing this via API.

# ---------------------------------------------------------------------------
# Asset storage: R2 bucket + edge Worker that serves the CCM-mirrored asset
# trees on the app origin. The Worker keeps the root-relative /documents/,
# /elaws/, /amended/, /laws/ paths baked into stored version HTML resolving
# verbatim, so no HTML rewrite is needed. See asset-proxy.js for the handler.
#
# Manual prerequisites (not creatable on the free plan / not S3-key-minting):
#   * The cloudflare_api_token used by this provider needs Workers Scripts:Edit
#     and Workers R2 Storage:Edit on the account.  It also needs Turnstile:Read
#     for the widget below; without it, every plan fails with a 403 when it
#     reads the widget.  An apply that changes the widget needs Turnstile:Edit.
#   * R2 *S3 access keys* for the upload side (Django sync_images --backend r2)
#     are minted under R2 > Manage R2 API Tokens in the dashboard and stored as
#     secrets — the serving Worker uses the binding below and needs no keys.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Edge caching for the read surfaces.
#
# Cloudflare does not cache HTML unless a rule says to, and these five views
# are the whole cost of the site: nearly all traffic is declared crawlers, and
# a provision permalink renders the matched provision *and its whole subtree*.
# The origin already answers 304 from the corpus stamp (core/http_cache.py);
# this stops the request reaching Django at all.
#
# Two rules the app and this file must agree on, or the tier gate leaks:
#
#   * A signed-in reader must never be served a stored copy.  The expression
#     below bypasses the cache whenever a Django session cookie is present,
#     and the app independently sends "private, no-store" on those responses,
#     so either mechanism alone is sufficient.
#   * "respect_origin" is deliberate.  The app decides how long a copy may
#     live (core.http_cache.EDGE_MAX_AGE) because the app is what knows when
#     the corpus changed.  Setting a TTL here would put that decision in two
#     places that cannot see each other.
#
# The print routes are excluded: an anonymous request to one is a redirect to
# the login page, which is about the reader, not the corpus.
# ---------------------------------------------------------------------------
resource "cloudflare_ruleset" "cache" {
  zone_id = data.cloudflare_zone.this.id
  name    = "Cache the read surfaces for anonymous readers"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [{
    ref         = "cache_anonymous_read_surfaces"
    description = "Store corpus pages at the edge unless the reader is signed in"
    expression = join(" and ", [
      "(starts_with(http.request.uri.path, \"/provision/\") or starts_with(http.request.uri.path, \"/regulation/\") or starts_with(http.request.uri.path, \"/edition/\") or starts_with(http.request.uri.path, \"/compare/\"))",
      "not http.request.uri.path contains \"/print/\"",
      "not http.request.headers[\"cookie\"][0] contains \"sessionid=\"",
    ])
    action = "set_cache_settings"
    action_parameters = {
      cache = true
      edge_ttl = {
        mode = "respect_origin"
      }
      browser_ttl = {
        mode = "respect_origin"
      }
    }
  }]
}

# A challenge for the print routes and the login page they redirect to.
#
# A crawler with current browser user agents and rotating IPs walks every
# provision's print link, although robots.txt refuses /provision/*/print/ and
# /accounts/.  Over 7 days to 24 September 2026 it made about 470 print
# requests and 2,400 login-page requests a day.  Each one wakes the Neon
# compute: the print view reads the provision before it redirects, and the
# login page renders the masthead, which reads CorpusCurrency.
#
# A managed challenge, not a block: an anonymous person who clicks a print
# link passes it, usually with no click, and then sees the login page.  A
# signed-in reader carries the session cookie and never meets the challenge.
# The query test has an encoded form because a client may send "next" encoded.
resource "cloudflare_ruleset" "firewall_custom" {
  zone_id = data.cloudflare_zone.this.id
  name    = "Challenge crawlers on the print routes"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [{
    ref         = "challenge_anonymous_print_requests"
    description = "Challenge anonymous requests for a print route or its login redirect"
    expression = join(" and ", [
      "((starts_with(http.request.uri.path, \"/provision/\") and http.request.uri.path contains \"/print/\") or http.request.uri.path eq \"/compare/print/\" or (starts_with(http.request.uri.path, \"/accounts/\") and (http.request.uri.query contains \"/print/\" or lower(http.request.uri.query) contains \"%2fprint%2f\")))",
      "not http.request.headers[\"cookie\"][0] contains \"sessionid=\"",
    ])
    action = "managed_challenge"
  }]
}

# The bot check on the app's signup and password-reset forms
# (accounts/turnstile.py in the app).  Made in the dashboard on 2026-09-24 and
# imported here (envs/prod/main.tf), so every Cloudflare object has one home.
#
# The app holds the two halves: the site key is a literal in the app's
# settings/base.py, and the secret is TURNSTILE_SECRET_KEY in the
# app_runtime_secrets bundle.  Replacing this widget issues a new pair, and
# every signup then fails until both are updated.  A change to `domains` or
# `mode` is an update in place and keeps the pair.
#
# localhost and 127.0.0.1 are here so a developer can run the real check.  The
# app's production settings refuse a token whose hostname is not the site's.
resource "cloudflare_turnstile_widget" "forms" {
  account_id = var.account_id
  name       = "codechronicle.ca (Spin)"
  mode       = "managed"
  # Cloudflare stores the list sorted, and Terraform compares a list by
  # position, so an unsorted list plans an update that changes nothing.
  domains = sort([var.domain, "localhost", "127.0.0.1"])
}

resource "cloudflare_r2_bucket" "assets" {
  account_id    = var.account_id
  name          = var.asset_bucket_name
  location      = var.asset_bucket_location
  storage_class = "Standard"
}

resource "cloudflare_workers_script" "asset_proxy" {
  account_id  = var.account_id
  script_name = "codechronicle-asset-proxy"
  content     = file("${path.module}/asset-proxy.js")
  main_module = "asset-proxy.js"

  bindings = [
    {
      name        = "ASSETS"
      type        = "r2_bucket"
      bucket_name = cloudflare_r2_bucket.assets.name
    },
    # The asset-token secret. The app signs "documents/" URLs with the same
    # string (ASSET_SIGNING_KEY in the app_runtime_secrets bundle); if the two
    # differ, every page scan 403s. The Worker refuses those keys outright when
    # this binding is absent, so a half-applied change fails closed.
    {
      name = "ASSET_SIGNING_KEY"
      type = "secret_text"
      text = var.asset_signing_key
    },
  ]

  # The saved Workers Logs are on (dashboard, after the 2026-08-22 apply).
  # Without these lines every plan turns them off again.
  observability = {
    enabled            = true
    head_sampling_rate = 1
    logs = {
      enabled            = true
      head_sampling_rate = 1
      invocation_logs    = true
      persist            = true
    }
  }
}

# One route per (subdomain, prefix) pair — assets must resolve on whichever
# host served the page. The Worker short-circuits these paths at the edge,
# ahead of the nginx/Django origin.
locals {
  asset_routes = {
    for pair in setproduct(var.subdomains, var.asset_path_prefixes) :
    "${pair[0]}-${pair[1]}" => { subdomain = pair[0], prefix = pair[1] }
  }
}

resource "cloudflare_workers_route" "assets" {
  for_each = local.asset_routes

  zone_id = data.cloudflare_zone.this.id
  pattern = "${each.value.subdomain}.${var.domain}/${each.value.prefix}/*"
  script  = cloudflare_workers_script.asset_proxy.script_name
}

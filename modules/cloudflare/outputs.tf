output "zone_id" {
  value = data.cloudflare_zone.this.id
}

output "domain_name" {
  value       = "${var.primary_subdomain}.${var.domain}"
  description = "Canonical host."
}

output "domain_names" {
  value       = [for s in var.subdomains : "${s}.${var.domain}"]
  description = "All served hosts."
}

output "record_ids" {
  value = { for k, r in cloudflare_dns_record.app : k => r.id }
}

# The public half only.  The secret stays in the state and the bundle, never in
# an output, so nothing prints it.
output "turnstile_sitekey" {
  value = cloudflare_turnstile_widget.forms.sitekey
}

output "asset_bucket_name" {
  value = cloudflare_r2_bucket.assets.name
}

output "asset_worker_routes" {
  value = [for r in cloudflare_workers_route.assets : r.pattern]
}

output "public_dashboard_url" {
  description = "The link to share. Stable as long as public_access_token is unchanged."
  value       = "https://${var.stack_slug}.grafana.net/public-dashboards/${grafana_dashboard_public.showcase.access_token}"
}

variable "stack_slug" {
  description = "Grafana Cloud stack name, the part before .grafana.net."
  type        = string
  default     = "merryserval899"
}

variable "public_access_token" {
  description = <<-EOT
    Token in the public dashboard URL (/public-dashboards/<token>). Pinned so
    that recreating the share keeps the same link. Leave null to let Grafana
    generate one.
  EOT
  type        = string
  default     = "10ebea18591f420692ff3805e1850a46"
}

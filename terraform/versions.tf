terraform {
  required_version = ">= 1.6"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.46"
    }
  }
}

# Authenticates with a Grafana service account token read from the
# GRAFANA_AUTH environment variable, so no credential is ever written to a
# file in this directory.
provider "grafana" {
  url = "https://${var.stack_slug}.grafana.net"
}

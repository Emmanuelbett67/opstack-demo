# The Grafana side of the live demo: where the showcase dashboard lives, the
# dashboard itself, and its public link.
#
# Alert rules are not here. They are Prometheus-style rules evaluated by
# Grafana Cloud's Mimir, and cloud/load-rules.sh uploads the same files CI
# unit-tests. The Grafana provider manages Grafana-managed alerts, a different
# system, and duplicating the rules in HCL would mean two sources of truth.

# Every Grafana Cloud stack ships a Prometheus data source with this name.
data "grafana_data_source" "prometheus" {
  name = "grafanacloud-${var.stack_slug}-prom"
}

locals {
  # showcase.json is written for manual import: it asks for its data source
  # through ${DS_PROMETHEUS} and lists that request under __inputs. Bind the
  # placeholder to the real data source and drop the import-only key.
  showcase_raw = replace(
    file("${path.module}/../cloud/showcase.json"),
    "$${DS_PROMETHEUS}",
    data.grafana_data_source.prometheus.uid,
  )
  showcase = { for k, v in jsondecode(local.showcase_raw) : k => v if k != "__inputs" }
}

resource "grafana_folder" "opstack" {
  uid   = "opstack"
  title = "OpStack"
}

resource "grafana_dashboard" "showcase" {
  folder      = grafana_folder.opstack.uid
  config_json = jsonencode(local.showcase)

  # Adopts the copy imported by hand before this existed, same uid.
  overwrite = true
}

resource "grafana_dashboard_public" "showcase" {
  dashboard_uid = grafana_dashboard.showcase.uid
  access_token  = var.public_access_token

  is_enabled             = true
  share                  = "public"
  time_selection_enabled = true
  annotations_enabled    = false
}

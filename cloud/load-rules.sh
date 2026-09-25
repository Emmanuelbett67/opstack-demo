#!/bin/sh
# Upload the alert rules in ../prometheus/rules to Grafana Cloud.
#
# The rule files are shared with the local Prometheus, which rejects the
# `namespace:` key Grafana Cloud's mimirtool requires. So each file is copied
# to a temporary directory with a namespace added, and the copies are loaded.
# Rerun after changing any rule; loading replaces groups of the same name.
set -eu

cd "$(dirname "$0")"
set -a; . ./.env; set +a

# mimirtool wants the bare host of the remote write URL; it adds the API path.
address="${GRAFANA_CLOUD_PROM_URL%%/api/*}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for f in ../prometheus/rules/*.yml; do
  name="$(basename "$f" .yml)"
  { echo "namespace: opstack-demo-$name"; cat "$f"; } > "$tmp/$name.yml"
done

files="$(cd "$tmp" && for f in *.yml; do printf '/rules/%s ' "$f"; done)"

# shellcheck disable=SC2086  # $files is a deliberate word list
docker run --rm -v "$tmp:/rules:ro" grafana/mimirtool:2.17.0 \
  rules load \
  --address="$address" \
  --id="$GRAFANA_CLOUD_PROM_USER" \
  --key="$GRAFANA_CLOUD_TOKEN" \
  $files

echo "Loaded. Check Alerting > Alert rules in Grafana Cloud."

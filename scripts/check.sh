#!/bin/sh
# Every static check the repository has, in one place. CI runs exactly this,
# so a green run locally means a green run in CI.
#
# Tools run from the same pinned images compose.yaml uses, so the versions
# that validate a config are the versions that load it. Needs only Docker.
set -eu

cd "$(dirname "$0")/.."
root="$(pwd)"

PROMETHEUS=prom/prometheus:v3.5.0
ALERTMANAGER=prom/alertmanager:v0.28.1
LOKI=grafana/loki:3.5.0
ALLOY=grafana/alloy:v1.10.0
PYTHON=python:3.12-slim

step() { printf '\n==> %s\n' "$1"; }
run() { docker run --rm -i -v "$root:/w:ro" -w /w "$@"; }
promtool() { docker run --rm -i -v "$root/prometheus:/etc/prometheus:ro" -v "$root:/w:ro" -w /w --entrypoint promtool "$PROMETHEUS" "$@"; }

step "Prometheus config and rule syntax"
promtool check config /etc/prometheus/prometheus.yml
promtool check rules prometheus/rules/*.yml

step "Alert rule unit tests"
promtool test rules prometheus/tests/*.test.yml

step "Alertmanager config"
run --entrypoint amtool "$ALERTMANAGER" check-config alertmanager/alertmanager.yml

step "Loki config"
run "$LOKI" -config.file=/w/loki/loki.yml -verify-config

step "Alloy configs are formatted (alloy fmt)"
for f in collectors/linux/config.alloy cloud/config.alloy; do
  run --entrypoint /bin/alloy "$ALLOY" fmt "$f" > /tmp/alloy-fmt.out
  if ! diff -u "$f" /tmp/alloy-fmt.out; then
    echo "$f is not formatted; run: alloy fmt -w $f" >&2
    exit 1
  fi
  echo "ok  $f"
done

step "Simulator output is valid Prometheus exposition"
for profile in database switch; do
  exposition="$(run "$PYTHON" python -c "
import sys
sys.path.insert(0, 'collectors/simulated')
import simulator
sys.stdout.write(simulator.PROFILES['$profile']().render())
")"
  # ifName and ifAlias are camelCase on purpose: they are the IF-MIB names the
  # real SNMP exporter emits, and dashboards and rules match on them. That one
  # lint is accepted; anything else promtool reports fails the check.
  problems="$(printf '%s\n' "$exposition" | promtool check metrics 2>&1 \
    | grep -v "label names should be written in 'snake_case' not 'camelCase'" || true)"
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" >&2
    exit 1
  fi
  echo "ok  $profile"
done

step "Dashboards: valid JSON, known datasources, unique panel ids"
run "$PYTHON" python - <<'PY'
import json, pathlib, sys

allowed = {"prometheus", "loki", "${DS_PROMETHEUS}"}
failed = False
for path in sorted(pathlib.Path(".").glob("**/*.json")):
    if "node_modules" in path.parts:
        continue
    dash = json.loads(path.read_text())
    if "panels" not in dash:
        continue
    ids = [p["id"] for p in dash["panels"]]
    if len(ids) != len(set(ids)):
        print(f"FAIL {path}: duplicate panel ids"); failed = True
    for p in dash["panels"]:
        for t in [p] + p.get("targets", []):
            uid = (t.get("datasource") or {}).get("uid")
            if uid is not None and uid not in allowed:
                print(f"FAIL {path}: panel '{p.get('title')}' uses datasource {uid}"); failed = True
    print(f"ok  {path} ({len(ids)} panels)")
sys.exit(failed)
PY

step "Compose files resolve"
docker compose -f compose.yaml config -q && echo "ok  compose.yaml"
# The cloud file needs a .env to resolve; use the example if none exists.
if [ -f cloud/.env ]; then
  docker compose -f cloud/compose.yaml config -q
else
  cp cloud/.env.example cloud/.env
  trap 'rm -f "$root/cloud/.env"' EXIT
  docker compose -f cloud/compose.yaml config -q
fi
echo "ok  cloud/compose.yaml"

printf '\nAll checks passed.\n'

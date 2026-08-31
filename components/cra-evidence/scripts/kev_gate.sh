#!/usr/bin/env bash
# kev_gate.sh — fail the pipeline when the scan hits a CISA KEV entry (SPEC §4).
#
# Inputs (env vars, all optional):
#   SCAN_PATH    grype JSON to gate on       default: dist/scan.json
#   KEV_URL      CISA KEV catalogue feed     default: official CISA URL below
#   KEV_CACHE    local catalogue cache       default: dist/kev.json (max age 24h)
#   FAIL_ON_KEV  exit 1 on matches?          default: true
#   OUTPUT_DIR   output directory            default: dist
#
# Output:
#   $OUTPUT_DIR/kev_result.json — written BEFORE any non-zero exit:
#   evidence of the failure is itself evidence (CLAUDE.md rule).
#
# Exit codes:
#   0  gate passed (or matches found but FAIL_ON_KEV=false)
#   1  gate FAILED — KEV matches found and FAIL_ON_KEV=true
#   2  gate COULD NOT EVALUATE — no fresh catalogue and cache older than 7 days
#   3  required tool missing
set -euo pipefail

SCAN_PATH="${SCAN_PATH:-dist/scan.json}"
KEV_URL="${KEV_URL:-https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json}"
KEV_CACHE="${KEV_CACHE:-dist/kev.json}"
FAIL_ON_KEV="${FAIL_ON_KEV:-true}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"

# Make tools installed by `make tools` visible when invoked directly.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

for tool in jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found on PATH." >&2
    exit 3
  fi
done
if [ ! -f "$SCAN_PATH" ]; then
  echo "ERROR: scan not found at $SCAN_PATH — run scan_vulns.sh first." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$(dirname "$KEV_CACHE")"

# file_older_than <path> <minutes> — true if file is missing or older.
# Uses find(1) because stat(1) flags differ between macOS and Linux.
file_older_than() {
  [ ! -f "$1" ] && return 0
  [ -n "$(find "$1" -mmin +"$2" 2>/dev/null)" ]
}

# --- refresh the KEV catalogue cache (max age 24h = 1440 min) ---------------
if file_older_than "$KEV_CACHE" 1440; then
  echo "kev_gate: refreshing KEV catalogue from $KEV_URL"
  tmp="$(mktemp)"
  # Download failure must not abort the script here (set -e): the 7-day-old
  # cache fallback below decides whether we can still evaluate.
  if curl -fsSL --max-time 60 -o "$tmp" "$KEV_URL" && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$KEV_CACHE"
  else
    rm -f "$tmp"
    if file_older_than "$KEV_CACHE" 10080; then # 7 days
      echo "ERROR: KEV download failed and cache is missing or older than 7 days." >&2
      echo "ERROR: gate could not evaluate (this is NOT a gate failure)." >&2
      exit 2
    fi
    echo "WARNING: KEV download failed — using cache $KEV_CACHE (younger than 7 days)." >&2
  fi
fi

KEV_VERSION="$(jq -r '.catalogVersion // "unknown"' "$KEV_CACHE")"
KEV_DATE="$(jq -r '.dateReleased // "unknown"' "$KEV_CACHE")"
CHECKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- intersect scan CVEs with the KEV set, keeping package context ----------
# For every grype match, collect its CVE ids (primary + related), keep those
# present in the KEV set, and emit one row per (cve, package). Deduplicated.
jq --slurpfile kev "$KEV_CACHE" \
   --arg checked_at "$CHECKED_AT" \
   --arg kev_version "$KEV_VERSION" \
   --arg kev_date "$KEV_DATE" '
  ($kev[0].vulnerabilities | map({(.cveID): true}) | add // {}) as $kevset
  | [ .matches[]
      | . as $m
      | ([$m.vulnerability.id] + [$m.relatedVulnerabilities[]?.id]) as $ids
      | $ids[]
      | select($kevset[.] == true)
      | { cve: .,
          package: $m.artifact.name,
          installed_version: $m.artifact.version,
          severity: $m.vulnerability.severity }
    ] | unique as $matches
  | { checked_at: $checked_at,
      kev_catalog_version: $kev_version,
      kev_catalog_date: $kev_date,
      cve_matches: $matches,
      gate: (if ($matches | length) > 0 then "fail" else "pass" end) }
' "$SCAN_PATH" > "$OUTPUT_DIR/kev_result.json"

GATE="$(jq -r .gate "$OUTPUT_DIR/kev_result.json")"
MATCH_COUNT="$(jq '.cve_matches | length' "$OUTPUT_DIR/kev_result.json")"

echo "kev_gate: catalogue $KEV_VERSION ($KEV_DATE), result -> $OUTPUT_DIR/kev_result.json"

if [ "$GATE" = "fail" ]; then
  # Loud, unmissable output — this is the CI log line an auditor will read.
  echo "==================================================================" >&2
  echo "  KEV GATE: FAIL — $MATCH_COUNT match(es) in the CISA Known" >&2
  echo "  Exploited Vulnerabilities catalogue (actively exploited!):" >&2
  jq -r '.cve_matches[] | "    \(.cve)  \(.package) \(.installed_version)  [\(.severity)]"' \
    "$OUTPUT_DIR/kev_result.json" >&2
  echo "==================================================================" >&2
  if [ "$FAIL_ON_KEV" = "true" ]; then
    exit 1
  fi
  echo "kev_gate: FAIL_ON_KEV=false — recording failure but not blocking." >&2
  exit 0
fi

echo "kev_gate: PASS — no KEV-listed CVEs in $SCAN_PATH"

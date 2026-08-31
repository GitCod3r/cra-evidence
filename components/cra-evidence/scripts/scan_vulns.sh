#!/usr/bin/env bash
# scan_vulns.sh — scan an SBOM for known vulnerabilities (SPEC §3).
#
# NEVER fails on findings — gating is kev_gate.sh's job. This script only
# fails when it cannot produce valid scan output.
#
# Inputs (env vars, all optional):
#   SBOM_PATH    SBOM to scan                default: dist/sbom.cdx.json
#   OUTPUT_DIR   output directory            default: dist
#
# Outputs:
#   $OUTPUT_DIR/scan.json   grype JSON (machine-readable, consumed by kev_gate.sh)
#   $OUTPUT_DIR/scan.txt    grype table (for humans)
#
# Exit codes: 0 ok · 1 scan output invalid · 3 required tool missing
set -euo pipefail

SBOM_PATH="${SBOM_PATH:-dist/sbom.cdx.json}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"

# Make tools installed by `make tools` visible when the script is invoked
# directly (outside the Makefile, which already prepends this to PATH).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

# Refuse to run without the tool — never auto-install in CI (CLAUDE.md rule).
if ! command -v grype >/dev/null 2>&1; then
  echo "ERROR: grype not found on PATH. Run 'make tools' locally, or use a CI image that ships grype." >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found on PATH." >&2
  exit 3
fi
if [ ! -f "$SBOM_PATH" ]; then
  echo "ERROR: SBOM not found at $SBOM_PATH — run generate_sbom.sh first." >&2
  exit 1
fi

echo "scan_vulns: grype $(grype version -o json | jq -r .version) on ${SBOM_PATH}"

mkdir -p "$OUTPUT_DIR"

# One grype run, two outputs: JSON for machines, table for humans.
# `|| true` on nothing: grype exits 0 on findings unless --fail-on is set,
# and we deliberately do not set it (gating happens in kev_gate.sh).
grype "sbom:$SBOM_PATH" \
  -o "json=$OUTPUT_DIR/scan.json" \
  -o "table=$OUTPUT_DIR/scan.txt" \
  --quiet

# Post-check: the gate script depends on .matches existing.
jq -e '.matches | type == "array"' "$OUTPUT_DIR/scan.json" >/dev/null \
  || { echo "ERROR: $OUTPUT_DIR/scan.json has no .matches array" >&2; exit 1; }

# Human summary: finding counts by severity, worst first.
echo "scan_vulns: findings by severity:"
jq -r '
  [.matches[].vulnerability.severity]
  | group_by(.)
  | map("  \(.[0]): \(length)")
  | if length == 0 then ["  (none)"] else . end
  | .[]
' "$OUTPUT_DIR/scan.json"

TOTAL="$(jq '.matches | length' "$OUTPUT_DIR/scan.json")"
echo "scan_vulns: OK — $TOTAL findings -> $OUTPUT_DIR/scan.json, $OUTPUT_DIR/scan.txt"

#!/usr/bin/env bash
# push_evidence.sh — POST the evidence bundle to a Compliance OS ingest API.
#
# The final pipeline step: instead of a human downloading the CI artifact and
# re-uploading it in a browser, the pipeline pushes the bundle itself. The
# platform verifies integrity + signature server-side and auto-completes the
# matching per-release obligations (subject/tenant come from the token).
#
# Inputs (env vars):
#   INGEST_URL     platform endpoint, e.g. https://app.example.eu/api/ingest (required)
#   INGEST_TOKEN   per-product bearer token (cri_...), from a masked CI var (required)
#   EVIDENCE_DIR   bundle directory                default: dist/evidence
#
# Exit codes: 0 ok · 1 input missing/push rejected · 3 curl missing
set -euo pipefail

INGEST_URL="${INGEST_URL:-}"
INGEST_TOKEN="${INGEST_TOKEN:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-dist/evidence}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not found on PATH." >&2
  exit 3
fi
if [ -z "$INGEST_URL" ] || [ -z "$INGEST_TOKEN" ]; then
  echo "ERROR: INGEST_URL and INGEST_TOKEN are required (set CRA_INGEST_TOKEN as a masked CI variable)." >&2
  exit 1
fi
if [ ! -f "$EVIDENCE_DIR/manifest.json" ]; then
  echo "ERROR: $EVIDENCE_DIR/manifest.json missing — run the bundle stage first." >&2
  exit 1
fi

# Every file in the bundle, recursively, flattened to basenames (the platform
# matches manifest-claimed nested paths by basename).
ARGS=()
while IFS= read -r -d '' f; do
  ARGS+=(-F "files=@$f;filename=$(basename "$f")")
done < <(find "$EVIDENCE_DIR" -type f -print0 | sort -z)

echo "push_evidence: POST ${#ARGS[@]} parts -> $INGEST_URL"
HTTP_CODE=$(curl -sS -o /tmp/ingest_response.json -w "%{http_code}" \
  -H "Authorization: Bearer $INGEST_TOKEN" \
  "${ARGS[@]}" \
  "$INGEST_URL")

cat /tmp/ingest_response.json; echo ""
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: ingest rejected (HTTP $HTTP_CODE)." >&2
  exit 1
fi
echo "push_evidence: OK (HTTP 200)"

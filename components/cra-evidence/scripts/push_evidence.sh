#!/usr/bin/env bash
# push_evidence.sh — push the evidence bundle to a Compliance OS ingest API.
#
# The final pipeline step: instead of a human downloading the CI artifact and
# re-uploading it in a browser, the pipeline pushes the bundle itself. The
# platform verifies integrity + signature server-side and auto-completes the
# matching per-release obligations (subject/tenant come from the token).
#
# Transport (v0.3.0): direct-to-storage. The platform hands out one signed PUT
# URL per file ("begin"), the files go straight to the evidence store, and a
# final small call ("complete") verifies and vaults — so bundle size is not
# limited by the platform's request cap. If the platform predates "begin"
# (HTTP 404), the legacy single multipart POST is used instead.
#
# Inputs (env vars):
#   INGEST_URL     platform endpoint, e.g. https://app.example.eu/api/ingest (required)
#   INGEST_TOKEN   per-product bearer token (cri_...), from a masked CI var (required)
#   EVIDENCE_DIR   bundle directory                default: dist/evidence
# Exit codes: 0 ok · 1 input missing/push rejected · 3 curl or jq missing
set -euo pipefail

INGEST_URL="${INGEST_URL:-}"
INGEST_TOKEN="${INGEST_TOKEN:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-dist/evidence}"

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found on PATH." >&2
    exit 3
  fi
done
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
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$EVIDENCE_DIR" -type f -print0 | sort -z)
NAMES_JSON=$(printf '%s\n' "${FILES[@]}" | xargs -n1 basename | jq -R . | jq -cs '{files: .}')

RESP=/tmp/ingest_response.json
AUTH=(-H "Authorization: Bearer $INGEST_TOKEN")

echo "push_evidence: begin (${#FILES[@]} files) -> $INGEST_URL/begin"
HTTP_CODE=$(curl -sS -o "$RESP" -w "%{http_code}" "${AUTH[@]}" -H "Content-Type: application/json" \
  --data "$NAMES_JSON" "$INGEST_URL/begin")

if [ "$HTTP_CODE" = "404" ]; then
  # Legacy platform: one multipart POST (subject to the platform's request cap).
  echo "push_evidence: platform has no /begin — falling back to single POST"
  ARGS=()
  for f in "${FILES[@]}"; do ARGS+=(-F "files=@$f;filename=$(basename "$f")"); done
  HTTP_CODE=$(curl -sS -o "$RESP" -w "%{http_code}" "${AUTH[@]}" "${ARGS[@]}" "$INGEST_URL")
  cat "$RESP"; echo ""
  [ "$HTTP_CODE" = "200" ] || { echo "ERROR: ingest rejected (HTTP $HTTP_CODE)." >&2; exit 1; }
  echo "push_evidence: OK (HTTP 200)"
  exit 0
fi
[ "$HTTP_CODE" = "200" ] || { cat "$RESP"; echo ""; echo "ERROR: begin rejected (HTTP $HTTP_CODE)." >&2; exit 1; }

UPLOAD_ID=$(jq -r '.uploadId' "$RESP")
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  url=$(jq -r --arg n "$name" '.files[] | select(.name == $n) | .url' "$RESP")
  [ -n "$url" ] || { echo "ERROR: no upload slot for $name" >&2; exit 1; }
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/octet-stream" \
    --data-binary "@$f" "$url")
  [ "$code" = "200" ] || { echo "ERROR: upload of $name failed (HTTP $code)." >&2; exit 1; }
  echo "push_evidence: uploaded $name ($(wc -c < "$f") bytes)"
done

echo "push_evidence: complete -> $INGEST_URL/complete"
HTTP_CODE=$(curl -sS -o "$RESP" -w "%{http_code}" "${AUTH[@]}" -H "Content-Type: application/json" \
  --data "$(jq -cn --arg id "$UPLOAD_ID" '{uploadId: $id}')" "$INGEST_URL/complete")
cat "$RESP"; echo ""
[ "$HTTP_CODE" = "200" ] || { echo "ERROR: ingest rejected (HTTP $HTTP_CODE)." >&2; exit 1; }
echo "push_evidence: OK (HTTP 200)"

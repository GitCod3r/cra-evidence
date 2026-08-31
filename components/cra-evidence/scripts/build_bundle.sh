#!/usr/bin/env bash
# build_bundle.sh — assemble the evidence bundle + manifest (SPEC §4).
#
# Inputs (env vars — all optional, CI values fall back to git/local):
#   PRODUCT_NAME        default: CI_PROJECT_NAME, else git repo dir name
#   PRODUCT_VERSION     default: CI_COMMIT_TAG, else `git describe`
#   COMMIT_SHA          default: CI_COMMIT_SHA, else `git rev-parse HEAD`
#   PIPELINE_URL        default: CI_PIPELINE_URL, else "local"
#   JOB_ID              default: CI_JOB_ID, else "local"
#   RUNNER              default: CI_RUNNER_DESCRIPTION, else hostname
#   IMAGE_REF           default: widget-server:dev (recorded into manifest)
#   SUPPORT_PERIOD_END  default: unset -> null in manifest
#   OUTPUT_DIR          default: dist
#
# Reads (produced by the earlier stages, all under $OUTPUT_DIR):
#   sbom.cdx.json, scan.json, scan.txt, kev_result.json,
#   and signatures/ if the signing step ran.
#
# Outputs:
#   $OUTPUT_DIR/evidence/            the bundle directory (incl. manifest.json)
#   $OUTPUT_DIR/evidence-<product>-<version>-<shortsha>.tar.gz
#
# The manifest MUST validate against schema/evidence-bundle.schema.json —
# this script runs the validator itself and fails if it does not.
#
# Exit codes: 0 ok · 1 missing input / validation failure · 3 tool missing
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

OUTPUT_DIR="${OUTPUT_DIR:-dist}"

# CI values with local fallbacks (CLAUDE.md rule: runs without GitLab).
PRODUCT_NAME="${PRODUCT_NAME:-${CI_PROJECT_NAME:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}}"
PRODUCT_VERSION="${PRODUCT_VERSION:-${CI_COMMIT_TAG:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}}"
COMMIT_SHA="${COMMIT_SHA:-${CI_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}}"
PIPELINE_URL="${PIPELINE_URL:-${CI_PIPELINE_URL:-local}}"
JOB_ID="${JOB_ID:-${CI_JOB_ID:-local}}"
RUNNER="${RUNNER:-${CI_RUNNER_DESCRIPTION:-$(hostname)}}"
IMAGE_REF="${IMAGE_REF:-widget-server:dev}"
SUPPORT_PERIOD_END="${SUPPORT_PERIOD_END:-}"

for tool in jq python3 tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found on PATH." >&2
    exit 3
  fi
done

# sha256 helper — sha256sum on Linux/CI, shasum on macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- collect inputs ----------------------------------------------------------
for f in sbom.cdx.json scan.json scan.txt kev_result.json; do
  if [ ! -f "$OUTPUT_DIR/$f" ]; then
    echo "ERROR: $OUTPUT_DIR/$f missing — run the sbom/scan/gate stages first." >&2
    exit 1
  fi
done

EVIDENCE_DIR="$OUTPUT_DIR/evidence"
rm -rf "$EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR"
cp "$OUTPUT_DIR/sbom.cdx.json" "$OUTPUT_DIR/scan.json" "$OUTPUT_DIR/scan.txt" \
   "$OUTPUT_DIR/kev_result.json" "$EVIDENCE_DIR/"

# Signatures are optional: present only when the signing step ran (M4/CI).
if [ -d "$OUTPUT_DIR/signatures" ]; then
  cp -R "$OUTPUT_DIR/signatures" "$EVIDENCE_DIR/signatures"
fi

# --- tool versions: read back from the artifacts themselves ------------------
# (pins live in the Makefile; the evidence records what actually ran)
SYFT_VERSION="$(jq -r '[.metadata.tools.components[]? // .metadata.tools[]?] | map(select(.name == "syft")) | .[0].version // "unknown"' "$EVIDENCE_DIR/sbom.cdx.json")"
GRYPE_VERSION="$(jq -r '.descriptor.version // "unknown"' "$EVIDENCE_DIR/scan.json")"
# cosign: version of the binary if available, else null (signing not run).
if command -v cosign >/dev/null 2>&1; then
  COSIGN_VERSION="$(cosign version --json 2>/dev/null | jq -r '.gitVersion // empty' || true)"
  COSIGN_VERSION="${COSIGN_VERSION:-unknown}"
else
  COSIGN_VERSION=""
fi

# --- manifest ----------------------------------------------------------------
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KEV_DATE="$(jq -r '.kev_catalog_date // "unknown"' "$EVIDENCE_DIR/kev_result.json")"
KEV_GATE="$(jq -r '.gate' "$EVIDENCE_DIR/kev_result.json")"
COMPONENT_COUNT="$(jq '.components | length' "$EVIDENCE_DIR/sbom.cdx.json")"

# files[]: name + sha256 for everything in the bundle except manifest.json
# itself (it cannot contain its own hash). Signatures included when present.
FILES_JSON="["
first=true
while IFS= read -r -d '' f; do
  rel="${f#"$EVIDENCE_DIR"/}"
  $first || FILES_JSON+=","
  first=false
  FILES_JSON+="{\"name\":\"$rel\",\"sha256\":\"$(sha256_of "$f")\"}"
done < <(find "$EVIDENCE_DIR" -type f ! -name manifest.json -print0 | sort -z)

FILES_JSON+="]"

jq -n \
  --arg name "$PRODUCT_NAME" \
  --arg version "$PRODUCT_VERSION" \
  --arg commit "$COMMIT_SHA" \
  --arg speriod "$SUPPORT_PERIOD_END" \
  --arg url "$PIPELINE_URL" \
  --arg job_id "$JOB_ID" \
  --arg runner "$RUNNER" \
  --arg generated_at "$GENERATED_AT" \
  --arg syft "$SYFT_VERSION" \
  --arg grype "$GRYPE_VERSION" \
  --arg cosign "$COSIGN_VERSION" \
  --arg image_ref "$IMAGE_REF" \
  --arg kev_date "$KEV_DATE" \
  --arg kev_gate "$KEV_GATE" \
  --argjson component_count "$COMPONENT_COUNT" \
  --argjson files "$FILES_JSON" \
  --slurpfile scan "$EVIDENCE_DIR/scan.json" '
  { schema_version: "1.0",
    product: ({ name: $name, version: $version, commit_sha: $commit }
              + (if $speriod == "" then {} else { support_period_end: $speriod } end)),
    pipeline: { url: $url, job_id: $job_id, runner: $runner },
    generated_at: $generated_at,
    tools: { syft: $syft, grype: $grype,
             cosign: (if $cosign == "" then null else $cosign end) },
    inputs: { image_ref: $image_ref, kev_catalog_date: $kev_date },
    results: {
      component_count: $component_count,
      vuln_counts_by_severity:
        ([$scan[0].matches[].vulnerability.severity] | group_by(.)
         | map({(.[0]): length}) | add // {}),
      kev_gate: $kev_gate },
    files: $files }
' > "$EVIDENCE_DIR/manifest.json"

# --- validate the manifest against the schema --------------------------------
python3 "$REPO_ROOT/tests/validate_manifest.py" \
  "$REPO_ROOT/schema/evidence-bundle.schema.json" "$EVIDENCE_DIR/manifest.json" \
  || { echo "ERROR: manifest failed schema validation" >&2; exit 1; }

# --- sign the manifest (CI only, SIGN_MANIFEST=true) --------------------------
# The manifest is created here, after the cra:sign job already signed the
# SBOM — so its signature is produced here too, before tarring. The manifest
# cannot list its own signature files (self-reference), which is fine: the
# manifest signature transitively attests every file via the sha256 list.
if [ "${SIGN_MANIFEST:-false}" = "true" ]; then
  FILES="$EVIDENCE_DIR/manifest.json" SIG_DIR="$EVIDENCE_DIR/signatures" \
    bash "$(dirname "${BASH_SOURCE[0]}")/sign_artifacts.sh"
fi

# --- tarball ------------------------------------------------------------------
SHORT_SHA="$(printf '%s' "$COMMIT_SHA" | cut -c1-8)"
TARBALL="$OUTPUT_DIR/evidence-${PRODUCT_NAME}-${PRODUCT_VERSION}-${SHORT_SHA}.tar.gz"
# -C so the archive contains a clean top-level 'evidence/' directory.
tar -czf "$TARBALL" -C "$OUTPUT_DIR" evidence

echo "build_bundle: OK — $TARBALL"
echo "build_bundle: sha256 $(sha256_of "$TARBALL")"

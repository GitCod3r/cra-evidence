#!/usr/bin/env bash
# generate_sbom.sh — produce a CycloneDX SBOM for a container image (SPEC §3).
#
# Inputs (env vars, all optional):
#   IMAGE_REF    image to catalogue          default: widget-server:dev
#   OUTPUT_DIR   output directory            default: dist
#
# Output:
#   $OUTPUT_DIR/sbom.cdx.json   CycloneDX 1.x JSON
#
# Exit codes: 0 ok · 1 output failed validation · 3 required tool missing
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-widget-server:dev}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"

# Make tools installed by `make tools` visible when the script is invoked
# directly (outside the Makefile, which already prepends this to PATH).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

# Refuse to run without the tool — never auto-install in CI (CLAUDE.md rule).
# Versions are pinned in the Makefile; CI must use an image that ships syft.
if ! command -v syft >/dev/null 2>&1; then
  echo "ERROR: syft not found on PATH. Run 'make tools' locally, or use a CI image that ships syft." >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found on PATH." >&2
  exit 3
fi

# Record the exact tool version in the log; the bundle manifest (M3) reads it
# back out of the SBOM's own metadata.tools section.
echo "generate_sbom: syft $(syft version -o json | jq -r .version) on ${IMAGE_REF}"

mkdir -p "$OUTPUT_DIR"
SBOM_PATH="$OUTPUT_DIR/sbom.cdx.json"

syft "$IMAGE_REF" -o "cyclonedx-json=$SBOM_PATH" --quiet

# Post-checks: fail loudly rather than hand a broken SBOM to the next stage.
jq empty "$SBOM_PATH" || { echo "ERROR: $SBOM_PATH is not valid JSON" >&2; exit 1; }

BOM_FORMAT="$(jq -r '.bomFormat // empty' "$SBOM_PATH")"
if [ "$BOM_FORMAT" != "CycloneDX" ]; then
  echo "ERROR: bomFormat is '$BOM_FORMAT', expected 'CycloneDX'" >&2
  exit 1
fi

COMPONENT_COUNT="$(jq '.components | length' "$SBOM_PATH")"
if [ "$COMPONENT_COUNT" -eq 0 ]; then
  echo "ERROR: SBOM has zero components — wrong image ref or scratch base?" >&2
  exit 1
fi

echo "generate_sbom: OK — $COMPONENT_COUNT components -> $SBOM_PATH"

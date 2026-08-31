#!/usr/bin/env bash
# sign_artifacts.sh — cosign sign-blob the evidence artifacts (SPEC §5).
#
# Two modes, decided by which credential is present:
#   keyless   SIGSTORE_ID_TOKEN set (GitLab OIDC id_token, aud=sigstore).
#             cosign picks the token up from the env automatically.
#             Emits .bundle (canonical, what verify-blob consumes) plus
#             .sig + .pem extracted from the bundle for spec compatibility.
#   key-pair  COSIGN_PRIVATE_KEY set (CI variable). Emits .sig only;
#             transparency log deliberately skipped (offline-friendly).
#
# Verified against GitLab docs (docs.gitlab.com/ci/yaml/signing_examples/,
# checked 2026-07-12): id_tokens syntax and verify-blob flags are current.
# cosign v3 note: sign-blob now defaults to the sigstore bundle format and a
# remote signing config; legacy --output-signature requires
# --new-bundle-format=false and --use-signing-config=false (tested v3.1.1).
#
# Inputs (env vars):
#   FILES     space-separated files to sign   default: dist/sbom.cdx.json
#   SIG_DIR   where signatures go             default: dist/signatures
#
# Exit codes: 0 ok · 1 input missing/sign failed · 3 cosign missing ·
#             4 no signing credential available
set -euo pipefail

FILES="${FILES:-dist/sbom.cdx.json}"
SIG_DIR="${SIG_DIR:-dist/signatures}"

# Make tools installed by `make tools` visible when invoked directly.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

if ! command -v cosign >/dev/null 2>&1; then
  echo "ERROR: cosign not found on PATH. Run 'make tools' locally, or use a CI image that ships cosign." >&2
  exit 3
fi

# Pick the signing mode; refuse (distinct exit code) when neither credential
# exists so CI rules — not this script — decide whether signing is optional.
if [ -n "${SIGSTORE_ID_TOKEN:-}" ]; then
  MODE="keyless"
elif [ -n "${COSIGN_PRIVATE_KEY:-}" ]; then
  MODE="key"
else
  echo "ERROR: no signing credential — need SIGSTORE_ID_TOKEN (keyless) or COSIGN_PRIVATE_KEY." >&2
  exit 4
fi

mkdir -p "$SIG_DIR"
echo "sign_artifacts: mode=$MODE cosign=$(cosign version --json 2>/dev/null | jq -r '.gitVersion // "unknown"')"

for f in $FILES; do
  if [ ! -f "$f" ]; then
    echo "ERROR: cannot sign missing file $f" >&2
    exit 1
  fi
  base="$(basename "$f")"
  if [ "$MODE" = "keyless" ]; then
    # --yes: non-interactive consent to Rekor transparency-log upload.
    cosign sign-blob --yes --bundle "$SIG_DIR/$base.bundle" "$f"
    # Convenience copies extracted from the bundle (sigstore bundle v0.3):
    # base64 signature -> .sig, Fulcio DER certificate re-wrapped -> .pem.
    jq -r '.messageSignature.signature' "$SIG_DIR/$base.bundle" > "$SIG_DIR/$base.sig"
    if jq -e '.verificationMaterial.certificate.rawBytes' "$SIG_DIR/$base.bundle" >/dev/null; then
      { echo "-----BEGIN CERTIFICATE-----"
        jq -r '.verificationMaterial.certificate.rawBytes' "$SIG_DIR/$base.bundle" | fold -w 64
        echo "-----END CERTIFICATE-----"
      } > "$SIG_DIR/$base.pem"
    fi
  else
    # Key-pair fallback: legacy flat .sig, no remote signing config, no tlog.
    cosign sign-blob --yes \
      --key env://COSIGN_PRIVATE_KEY \
      --use-signing-config=false \
      --tlog-upload=false \
      --new-bundle-format=false \
      --output-signature "$SIG_DIR/$base.sig" \
      "$f"
    # Also emit the sigstore bundle (verification material for platform-side
    # verify, matching the keyless branch). Needs an empty signing config so
    # cosign v3 signs offline (no Fulcio/Rekor/TSA services).
    SC_TMP="$(mktemp)"
    printf '%s' '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}' > "$SC_TMP"
    cosign sign-blob --yes \
      --key env://COSIGN_PRIVATE_KEY \
      --signing-config "$SC_TMP" \
      --bundle "$SIG_DIR/$base.bundle" \
      "$f"
    rm -f "$SC_TMP"
  fi
  echo "sign_artifacts: signed $f -> $SIG_DIR/$base.sig"
done

echo "sign_artifacts: done. Verify keyless signatures with:"
echo "  cosign verify-blob <file> --bundle <file>.bundle \\"
echo "    --certificate-identity '<gitlab-url>/<project>//<ci-config-path>@<ref>' \\"
echo "    --certificate-oidc-issuer '<gitlab-url>'"

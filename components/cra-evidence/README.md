# cra-evidence component

GitLab CI/CD component that makes every release emit a signed, dated evidence
bundle (SBOM + vulnerability scan + KEV gate result). Four jobs:
`cra:sbom` → `cra:scan-gate` → `cra:sign` → `cra:bundle`, sharing `dist/`
via artifacts (`when: always` — evidence survives a failed gate).

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `image_ref` | yes | — | Container image to generate evidence for |
| `product_name` | yes | — | Product name recorded in the manifest |
| `stage` | no | `test` | Pipeline stage for all cra jobs |
| `product_version` | no | `''` | Empty = `$CI_COMMIT_TAG`, falling back to `$CI_COMMIT_SHORT_SHA` |
| `fail_on_kev` | no | `true` | Fail `cra:scan-gate` on a CISA-KEV-listed CVE |
| `sign` | no | `true` | Sign SBOM + manifest with cosign keyless (GitLab OIDC) |
| `evidence_upload_url` | no | `''` | Optional `gs://` or `s3://` prefix; empty = CI artifacts only |
| `support_period_end` | no | `''` | Declared support period end, recorded into the manifest |

## Usage

```yaml
include:
  # during development (component repo = your repo):
  - local: templates/cra-evidence.yml
  # at release, the versioned catalog reference instead:
  # - component: gitlab.com/nextgensolutionsltd/cra-evidence/cra-evidence@0.2.0
    inputs:
      stage: test
      image_ref: "$CI_REGISTRY_IMAGE/my-product:$CI_COMMIT_SHORT_SHA"
      product_name: my-product
      support_period_end: "2031-12-31"
```

The consuming pipeline must build and push `image_ref` in an earlier stage —
see `demo/widget-server/.gitlab-ci.yml` for a complete working example.

## Verifying a bundle (what your customers run)

Keyless signatures (the default) are verified against the GitLab OIDC
identity of the pipeline that produced them:

```sh
tar -xzf evidence-<product>-<version>-<sha>.tar.gz
cosign verify-blob evidence/manifest.json \
  --bundle evidence/signatures/manifest.json.bundle \
  --certificate-identity "https://gitlab.com/<group>/<project>//.gitlab-ci.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://gitlab.com"
```

The double slash between project path and CI config path is required. The
manifest lists a sha256 for every other file in the bundle, so verifying the
manifest signature attests the whole bundle; check any file with
`shasum -a 256 <file>` against `manifest.json`.

Key-pair fallback (when `COSIGN_PRIVATE_KEY` is used instead of OIDC; no
transparency log):

```sh
cosign verify-blob evidence/manifest.json \
  --key cosign.pub --insecure-ignore-tlog \
  --signature evidence/signatures/manifest.json.sig
```

## Design notes

- The SPEC lists `cra:sign` before `cra:bundle`, but the manifest is created
  by the bundle step — so `cra:sign` signs the SBOM, and `build_bundle.sh`
  signs the manifest itself (`SIGN_MANIFEST=true`) after schema validation
  and before tarring. All signatures ship inside the tarball.
- The manifest cannot list its own signature files (self-reference); the
  manifest signature transitively covers everything via the sha256 list.
- Jobs install pinned tools explicitly in `before_script` via `make tools`
  (versions pinned in the Makefile, the single pin location). A dedicated
  pre-baked CI image is tracked in BACKLOG.md.

## Scripts

All scripts: `set -euo pipefail`, inputs as env vars with defaults, outputs to
`dist/`. They refuse to run (exit 3) if their tool is missing — run
`make tools` locally; in CI use an image that ships the tool. Versions are
pinned in the Makefile only.

| Script | Inputs (defaults) | Outputs |
|---|---|---|
| `generate_sbom.sh` | `IMAGE_REF` (`widget-server:dev`), `OUTPUT_DIR` (`dist`) | `sbom.cdx.json` (CycloneDX; validated: JSON, `bomFormat`, non-empty components) |
| `scan_vulns.sh` | `SBOM_PATH` (`dist/sbom.cdx.json`), `OUTPUT_DIR` (`dist`) | `scan.json` (grype JSON), `scan.txt` (human table). Never fails on findings — gating is `kev_gate.sh`'s job |
| `kev_gate.sh` | `SCAN_PATH` (`dist/scan.json`), `KEV_URL` (CISA feed), `KEV_CACHE` (`dist/kev.json`, refreshed after 24h), `FAIL_ON_KEV` (`true`), `OUTPUT_DIR` (`dist`) | `kev_result.json` — written **before** any non-zero exit. Exit 1 = KEV match; exit 2 = could not evaluate (download failed and cache >7 days) |
| `build_bundle.sh` | `PRODUCT_NAME`/`PRODUCT_VERSION`/`COMMIT_SHA`/`PIPELINE_URL`/`JOB_ID`/`RUNNER` (CI vars, git/local fallbacks), `IMAGE_REF`, `SUPPORT_PERIOD_END` (optional), `OUTPUT_DIR` (`dist`) | `evidence/` dir (manifest.json + sbom + scan + kev_result [+ signatures/]) and `evidence-<product>-<version>-<shortsha>.tar.gz`; manifest is schema-validated before packaging |
| `sign_artifacts.sh` | — | M4 |

Exit codes: `0` ok · `1` invalid input/output (or KEV gate failure) ·
`2` gate could not evaluate · `3` required tool missing.

The manifest schema lives at `schema/evidence-bundle.schema.json`;
`make validate-bundle` re-validates an existing bundle.

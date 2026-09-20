# Changelog

## v0.2.1 — 2026-09-20

- GitHub Actions: the composite action now archives `dist/evidence` as a run
  artifact (`cra-evidence-<product_name>`, 90 days, `if: always()` — evidence
  of a failed gate is still evidence). Before, a consumer using only the
  action got no artifact unless they pushed to a platform or added their own
  upload step (found by the first customer walkthrough).
- No changes to the GitLab component or the scripts.

## v0.2.0 — 2026-08-31

First public release, split out of the private `cra-ready-toolkit` (which
remains the source of truth; this repo is synced at each release).

- GitLab CI/CD Catalog component (`templates/cra-evidence.yml`): `cra:sbom` →
  `cra:scan-gate` → `cra:sign` → `cra:bundle` → optional `cra:push` to a
  Compliance OS ingest endpoint. Remote consumption clones this repo at
  `toolkit_ref` — consumers vendor nothing.
- GitHub Actions composite action (`github-action/`), verified on a real
  runner: keyless OIDC signing, bundle signature `Verified OK` offline.
- Evidence bundle schema v1.0 (`schema/evidence-bundle.schema.json`) with
  manifest validation at build time.
- Tool pins: syft v1.46.0 · grype v0.115.0 · cosign v3.1.1.
- License: Apache-2.0.

(Version numbering continues from the toolkit's v0.1.0 GitLab-verified
component, 2026-07-12.)

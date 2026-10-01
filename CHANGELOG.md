# Changelog

## v0.3.0 — 2026-10-01

- `push_evidence.sh`: **direct-to-storage transport.** `begin` (one signed
  PUT URL per file) → PUT each file straight to the evidence store → `complete`
  (verify + vault). Bundle size is no longer limited by the platform's
  request cap (4 MB on the hosted platform). Falls back to the legacy single
  multipart POST when the platform returns 404 for `/begin`. Needs `jq`
  (already required by the gate).
- No change to the GitLab component or GitHub action inputs; both pick the
  new script up automatically via `toolkit_ref` / the action tag.

## v0.2.2 — 2026-09-30

- GitHub Actions: **evidence of a failed KEV gate is now archived.** The gate's
  verdict is captured instead of aborting the step, so the bundle is still
  signed, built, archived (and pushed when configured); the job then fails on
  the verdict in a final step. Before, a KEV hit skipped the bundle and the
  run ended with no artifact (found by the customer walkthrough, section 8).
- GitHub Actions: version falls back to the short commit SHA on branch
  builds, never the branch name (a release called `master` is meaningless).
- GitLab component: `cra:bundle` archives only `dist/evidence/` + the tarball
  (the working copies at the top of `dist/` confused consumers; the earlier
  jobs still archive theirs, so failed-gate evidence is unchanged).
- `build_bundle.sh`: the tarball no longer repeats the SHA when the version
  already is the SHA (`evidence-app-f601acdd.tar.gz`, not `…-f601acdd-f601acdd`).

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

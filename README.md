# cra-evidence

CI/CD component for **EU Cyber Resilience Act release evidence**: every release
emits a signed, dated evidence bundle — CycloneDX SBOM (syft), vulnerability
scan (grype), CISA KEV exploit gate, cosign-signed manifest — validated against
[`schema/evidence-bundle.schema.json`](schema/evidence-bundle.schema.json) and
optionally pushed straight to a [Compliance OS](https://compliance-os.eu)
ingest endpoint.

Works with **GitLab CI** (CI/CD Catalog component) and **GitHub Actions**
(composite action). Same scripts, same schema, keyless signing via each
platform's OIDC.

## GitLab

```yaml
include:
  - component: gitlab.com/nextgensolutionsltd/cra-evidence/cra-evidence@v0.2.0
    inputs:
      stage: test
      image_ref: "$CI_REGISTRY_IMAGE/my-product:$CI_COMMIT_SHORT_SHA"
      product_name: my-product
      toolkit_ref: v0.2.0            # pin the scripts to the same release
      evidence_api_url: https://<your-platform-domain>/api/ingest   # optional
# Settings > CI/CD > Variables: CRA_INGEST_TOKEN (masked) — optional, for cra:push
```

## GitHub

```yaml
permissions:
  contents: read
  id-token: write                    # keyless signing via GitHub OIDC
steps:
  - uses: actions/checkout@v5
  - uses: GitCod3r/cra-evidence/github-action@v0.2.1
    with:
      image_ref: ghcr.io/acme/my-product:${{ github.sha }}
      product_name: my-product
      evidence_api_url: https://<your-platform-domain>/api/ingest   # optional
    env:
      CRA_INGEST_TOKEN: ${{ secrets.CRA_INGEST_TOKEN }}             # optional
```

## What you get per release

On GitHub the bundle is archived as the run artifact `cra-evidence-<product>`;
on GitLab it is the `cra:bundle` job artifact (`dist/`).

```
dist/evidence/
  manifest.json          # product, pipeline provenance, tool versions,
                         # KEV catalogue date, sha256 for every file
  sbom.cdx.json          # CycloneDX SBOM
  scan.json / scan.txt   # grype vulnerability scan
  kev_result.json        # CISA KEV exploit-gate result (distinct exit codes)
  signatures/*.bundle    # cosign signature bundles (keyless via CI OIDC)
```

- **Evidence of failure is still evidence** — artifacts are archived even when
  the KEV gate fails the job.
- **Pinned tools, no silent installs** — versions live in the [Makefile](Makefile)
  and nowhere else.
- Full input reference: [components/cra-evidence/README.md](components/cra-evidence/README.md).

## Verifying a bundle offline

```sh
cosign verify-blob \
  --bundle dist/evidence/signatures/manifest.json.bundle \
  --certificate-identity "<your pipeline identity>" \
  --certificate-oidc-issuer "<https://gitlab.com | https://token.actions.githubusercontent.com>" \
  dist/evidence/manifest.json
```

## Provenance

This repository is the public, consumable part of the
`nextgensolutionsltd/cra-ready-toolkit` delivery kit (source of truth; synced
at each release). Both CI variants have been verified on real runs — green
pipelines with `cosign verify-blob: Verified OK` against the pinned identity.

License: [Apache-2.0](LICENSE). Not legal advice; the CRA obligations cited in
Compliance OS are quoted from the consolidated text (CELEX 02024R2847).

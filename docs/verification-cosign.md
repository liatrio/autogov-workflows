# Verification Using Cosign

How to verify autogov-workflows attestations using Sigstore's cosign, including image and blob verification.

Part of the [autogov-workflows](../README.md) docs.

It is also possible to use Sigstore's own [cosign](https://github.com/sigstore/cosign) to [verify bundles](https://blog.sigstore.dev/cosign-verify-bundles/) though this is [currently not documented](https://github.com/actions/attest-build-provenance/issues/162) and only through `cosign verify-blob-attestation` which requires other tools (regctl or Docker) to verify images in order to grab the necessary OCI artifacts.

*To be further agnostic, the below steps will not use the `gh attestation` command.*

## Verification Prerequisites

1. Install cosign:

```shell
# Using Homebrew
brew install cosign

# Or download directly from GitHub releases
# Visit: https://github.com/sigstore/cosign/releases
```

2. Create a trusted root file:

```shell
# Create the trusted root file for GitHub's Fulcio instance
gh attestation trusted-root | jq '.|select(.certificateAuthorities[0].uri=="fulcio.githubapp.com")' > github-trusted-root.json
```

3. Ensure you are authenticated with ghcr.io via Docker using a PAT with the package read permission:

```shell
# Login using PAT as the password
docker login ghcr.io
```

### Image Verification Prerequisites

Before verifying image/OCI attestations, you'll need:

Install regctl (if using the regctl method):

```shell
# Using Homebrew
brew install regclient

# Or download directly from GitHub releases
# Visit: https://github.com/regclient/regclient/releases
```

#### Verifying Images Using regctl

```shell
# Get the manifest
regctl manifest get --format raw-body ghcr.io/liatrio/autogov-workflows@<image_digest> > manifest.json

# Calculate digest
DIGEST="sha256-$(sha256sum manifest.json | awk '{ print $1 }')"

# Get the attestation bundle
regctl artifact get ghcr.io/liatrio/autogov-workflows:${DIGEST} > bundle.json

# Verify the attestation
cosign verify-blob-attestation \
  --bundle bundle.json \
  --trusted-root github-trusted-root.json \
  --new-bundle-format \
  --use-signed-timestamps \
  --insecure-ignore-sct \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity="https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-image.yaml@${github.ref}" \
  manifest.json
```

#### Verifying Images Using Docker

If you don't have regctl installed, you can use standard Docker commands:

```shell
# Get the manifest
docker manifest inspect ghcr.io/liatrio/autogov-workflows@<image_digest> > manifest.json

# Calculate digest
DIGEST="sha256-$(sha256sum manifest.json | awk '{ print $1 }')"

# Pull and extract the attestation bundle
docker pull ghcr.io/liatrio/autogov-workflows:${DIGEST}
docker save ghcr.io/liatrio/autogov-workflows:${DIGEST} -o bundle.tar
tar -xf bundle.tar
cat manifest.json | jq '.[0].Config' | xargs cat > bundle.json

# Verify the attestation
cosign verify-blob-attestation \
  --bundle bundle.json \
  --trusted-root github-trusted-root.json \
  --new-bundle-format \
  --use-signed-timestamps \
  --insecure-ignore-sct \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity="https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-image.yaml@${github.ref}" \
  manifest.json
```

### Verifying Blob Attestations

```shell
cosign verify-blob-attestation \
  --trusted-root github-trusted-root.json \
  --bundle bundle.jsonl \
  --use-signed-timestamps \
  --insecure-ignore-sct \
  --new-bundle-format \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity="https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-blob-offline.yaml@${github.ref}" \
  <path_to_blob>
```

# Workflows

## Attested Image Release

### When to Use

- This workflow is intended for building images
- This workflow is best suited for PR workflows and default (main) workflows

### How to Use

> replace <commit_sha> with the [latest tag/release commit sha](https://github.com/liatrio/demo-gh-autogov-workflows/tags)

```yaml
name: Build, Sign, and Verify Docker Image

on:
  workflow_dispatch:
  pull_request:
    types: [opened, synchronize, reopened]
    branches:
      - '**'
  push:
    branches:
      - main
    paths-ignore:
      - 'README.md'
      - 'catalog-info.yaml'

permissions:
  id-token: write
  attestations: write
  packages: write
  contents: write

jobs:
  build-image:
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/build-image.yaml@<commit_sha>
  attest-image:
    needs: build-image
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attest-image.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.build-image.outputs.image_digest }}
  attest-sbom:
    needs: build-image
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attest-sbom.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.build-image.outputs.image_digest }}
  attest-blob:
    needs: build-image
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attest-blob.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.build-image.outputs.image_digest }}
  verify:
    needs: [build-image, attest-image, attest-sbom, attest-blob]
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/verify.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.build-image.outputs.image_digest }}
  run-opa:
    needs: [build-image, verify]
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/run-opa.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.build-image.outputs.image_digest }}
  release:
    needs: [build-image, run-opa]
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attested-image-release.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.build-image.outputs.image_digest }}
```

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
  push:
    branches:
      - main
    paths-ignore:
      - 'README.md'
      - 'catalog-info.yaml'
  pull_request:
    types:
      - opened
      - synchronize
      - reopened
    branches:
      - '**'

permissions:
    id-token: write
    attestations: write
    packages: write
    contents: write

env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

jobs:
    build:
      uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attest-image-build.yaml@<commit_sha>

    sbom:
      needs: build
      uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attest-sbom.yaml@<commit_sha>
      secrets: inherit
      with:
        image_digest: ${{ needs.build.outputs.image_digest }}

    blob:
      needs: build
      uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attest-blob.yaml@<commit_sha>
      secrets: inherit
      with:
        image_digest: ${{ needs.build.outputs.image_digest }}

    release:
      needs: [build, sbom, blob]
      uses: liatrio/demo-gh-autogov-workflows/.github/workflows/attested-image-release.yaml@<commit_sha>
      secrets: inherit
      with:
        image_digest: ${{ needs.build.outputs.image_digest }}

```

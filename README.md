# Reusable Workflows using GitHub Artifact Attestations

## When to Use

- This workflow is intended for building images and attaching and/or the following:
  - blob
  - sbom

### How to Use

> replace <commit_sha> with the [latest tag/release commit sha](https://github.com/liatrio/demo-gh-autogov-workflows/tags)

```yaml
name: Caller Workflow

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths-ignore:
      - 'README.md'
      - 'catalog-info.yaml'
      - 'renovate.json'
  pull_request:
    types: [opened, synchronize, reopened]
    branches:
      - main

permissions:
  id-token: write
  attestations: write
  packages: write
  contents: write

jobs:
  attest:
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/rw-attest.yaml@<commit_sha>
  verify:
    needs: [attest]
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/rw-verify.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.attest.outputs.image_digest }}
      # verify_tag: <commit_sha> if not set, will use latest sha from main.
  run-opa:
    needs: [verify, attest]
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/rw-run-opa.yaml@<commit_sha>
    secrets: inherit
    with:
      image_digest: ${{ needs.attest.outputs.image_digest }}
  release:
    needs: [run-opa]
    uses: liatrio/demo-gh-autogov-workflows/.github/workflows/rw-release.yaml@<commit_sha>
    secrets: inherit
```

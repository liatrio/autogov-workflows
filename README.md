# Reusable Workflows using GitHub Artifact Attestations

[![lint](https://github.com/liatrio/autogov-workflows/actions/workflows/lint.yml/badge.svg)](https://github.com/liatrio/autogov-workflows/actions/workflows/lint.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/liatrio/autogov-workflows/badge)](https://scorecard.dev/viewer/?uri=github.com/liatrio/autogov-workflows)
[![Release](https://img.shields.io/github/v/release/liatrio/autogov-workflows?sort=semver)](https://github.com/liatrio/autogov-workflows/releases)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

You cannot trust a build artifact unless you can prove who built it and how. These reusable [GitHub Actions](https://docs.github.com/actions) workflows build your artifacts (OCI images or blobs), attest them — generating [SLSA](https://slsa.dev/spec/v1.2/about) build [provenance](https://slsa.dev/provenance/v1) (signed, verifiable metadata about how an artifact was built), an [SBOM](https://www.cisa.gov/sbom) (software bill of materials), and a vulnerability scan — and then verify those attestations against [OPA/Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) policy to emit a pass/fail Verification Summary Attestation (VSA) that gates releases. Each step is driven by the [autogov](https://github.com/liatrio/autogov) CLI, so you get the same supply-chain checks in CI without wiring the tooling together yourself, powered by [Sigstore](https://www.sigstore.dev/) (Rekor/Fulcio/Cosign). Drop the workflows into your repo and call them from your own CI for a paved path to a hardened, policy-gated release pipeline.

These workflows are part of the [autogov](https://github.com/liatrio/autogov) ecosystem. For the project overview and the CLI that powers them, start with the flagship repo: [github.com/liatrio/autogov](https://github.com/liatrio/autogov).

- [Quick Start Guide](#quick-start-guide)
- [Attesting the Workflow Files](#attesting-the-workflow-files)
- [Paving the Path](#paving-the-path)
- [Achieving SLSA Build Levels Using Reusable Workflows](#achieving-slsa-build-levels-using-reusable-workflows)
  - [Verification / cert-identity](#verification--cert-identity)
  - [Certificate Identities](#certificate-identities)
  - [Verification Using Cosign](#verification-using-cosign)
  - [Verification Using ORAS](#verification-using-oras)
  - [L3: Isolation of Build from Attest](#l3-isolation-of-build-from-attest)
  - [L2: Ensure a Trusted Build Environment](#l2-ensure-a-trusted-build-environment)
  - [L1: Documented Build Parameters](#l1-documented-build-parameters)
  - [Workflow Inputs and SLSA](#workflow-inputs-and-slsa)
  - [Why No Pull Request?](#why-no-pull-request)
- [Usage](#usage)
  - [Tools Used](#tools-used)
  - [Limiting Inputs by Wrapping](#limiting-inputs-by-wrapping-reusable-workflow-calls)
  - [Access](#access)
  - [Inputs](#inputs)
  - [Outputs](#outputs)
  - [Example Workflow Snippets](#example-workflow-snippets)
- [Troubleshooting](#troubleshooting)
- [Additional Resources](#additional-resources)

## Quick Start Guide

1. **Configure Access**:
   Ensure you have the necessary permissions and tokens configured in your remote caller repository described in the [access section](#access) below.
   - **Permissions**: Ensure you have the [necessary permissions to run the workflows](#workflow-access).
   - **Tokens**: Set up the [required tokens](#repository-access) for policy bundle access.

2. **Create Your Local Composite Actions**:
   The reusable workflows execute a locally-defined composite action to build your artifact. Copy one of the reference actions into your repo and adjust its build step:
   - **`build-image`** — see [`.github/actions/build-image/action.yaml`](./.github/actions/build-image/action.yaml). Builds + pushes an OCI image and computes a preemptive semver tag via `autogov release plan`; adjust the `Build and push` step for your image.
   - **`build-blob`** — see [`.github/actions/build-blob/action.yaml`](./.github/actions/build-blob/action.yaml). Emits placeholder blobs; replace its build step so it produces your real artifact(s) at the path(s) you pass as `subject-path` (for an npm package, that's the `npm`/`yarn pack` output, e.g. `liatrio-simple-greeter-1.0.0.tgz`).

3. **Create Your Caller Workflows / Configure Inputs**:

   Pick one of the following jobs depending on the desired build type and permissions (`cw-build.yaml`):

```yaml
name: Build Entrypoint Caller Workflow

on:
    workflow_dispatch:
    push:

jobs:
  build-image:
    permissions:
      id-token: write
      attestations: write
      packages: write
      contents: write
    uses: liatrio/autogov-workflows/.github/workflows/rw-build-image.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
    secrets: inherit
    with:
      subject-name: ${{ github.repository }}
      registry: ghcr.io
      cert-identity: https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-image.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release

  build-blob:
    permissions:
      id-token: write
      attestations: write
      packages: read
      contents: write
    uses: liatrio/autogov-workflows/.github/workflows/rw-build-blob.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
    secrets: inherit
    with:
      subject-path: |
        i_am_blob
        i_am_another_blob
      cert-identity: https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-blob.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release

  build-blob-offline:
    permissions:
      id-token: write
      attestations: write
      contents: write
    uses: liatrio/autogov-workflows/.github/workflows/rw-build-blob-offline.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
    secrets: inherit
    with:
      subject-path: |
        i_am_blob
        i_am_another_blob
      cert-identity: https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-blob-offline.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
```

4. **Run the Workflow**:
   Trigger the workflow using one of the supported event types:

    - [`push`] / [creation or update of a git tag or branch](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#create).
    - [`release`] / [creation or update of a GitHub release](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#release).
    - [`create`] / [creation of a git tag or branch](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#push).
    - [`workflow_dispatch`] / [enables the ability to trigger workflow manually](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#workflow_dispatch).

5. **Check Results**:
   Review the workflow logs and the uploaded **Verification Summary Attestation
   (VSA)** artifact. The `autogov` CLI performs signature verification, OPA/Rego
   policy evaluation, and VSA generation in a single step. A passing run produces
   `vsa-PASSED.json`. A failing policy evaluation produces `vsa-FAILED.json`; the
   FAILED VSA is still attested and uploaded (the record is preserved), and the job
   then fails and the release is skipped — unless `allow-failed-vsa: true` is set,
   which keeps the run advisory. The gate is default-deny: it ships only on an
   explicit `PASSED` result, so any non-PASSED outcome (FAILED, or a missing/unknown
   VSA) also blocks the release.

## Attesting the Workflow Files

This repository ships reusable workflows, consumed via `uses: liatrio/autogov-workflows/.github/workflows/rw-*.yaml@<sha>`. Its own `cw-build.yaml` dogfoods the pipeline: it runs `rw-build-blob-offline` over the real product — the `rw-*.yaml` reusables — to attest them (SLSA build-provenance, SBOM, metadata, dependency-scan) and verify them offline into a VSA, then cuts the release attaching that evidence. Signed with the repository's own identity.

> **Release assets:** this repository's own releases ship `cert-identities.json` (the signer allowlist), the full attestation bundle `autogov.attestations.intoto.jsonl` (covering the `rw-*.yaml` reusables), `vsa-PASSED.json` proving those attestations verified against policy, and `autogov-workflows.intoto.jsonl` — the single build-provenance statement for OpenSSF Scorecard's release-provenance detection. The `rw-*.yaml` reusables themselves are **not** attached as release assets (they're consumed via `uses: ...@<ref>` and attested by digest in the bundle); `rw-build-blob`/`rw-build-blob-offline` expose `release-blob-asset` (default `true`) to control that, and consumer releases built through `rw-build-image` / `rw-build-blob` attach the same evidence shape for their own artifact.

Consumers can verify the publisher identity of a reusable workflow they reference:

```bash
gh attestation verify .github/workflows/rw-attest-image.yaml --repo liatrio/autogov-workflows
```

This gives **publisher identity** (cryptographic proof the file was produced by this repository's CI under the GitHub Actions OIDC identity), a signal for **consumer policy enforcement**, and **defense in depth** alongside pinning. It does **not** add file integrity beyond the commit-SHA pin — `uses: ...@<sha>` already content-addresses the exact file, so the pin is the integrity guarantee; the attestation is about *who* published the file and *how*, and is not revoked if the file is later deleted or renamed.

## Paving the Path

To achieve SLSA Build Level 3, we recommend using GitHub-native tools and reusable workflows. Our approach is inspired by the slsa-framework's implementations, specifically [slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#build-your-own-builder-byob-framework) and [slsa-verifier](https://github.com/slsa-framework/slsa-verifier).

["The only way to interact with a reusable workflow is through the input parameters it exposes to the calling workflow."](https://github.com/slsa-framework/slsa-github-generator/blob/3d34abbe34b268bb6c02651df2117370e8cee1bd/SPECIFICATIONS.md#interference-between-jobs)

The source repository contains the caller workflow, which interacts with the trusted builder (reusable workflow) to build the artifacts and generate signed provenance; the artifacts and their signed provenance are then securely stored and can be verified to ensure their integrity.

GitHub Artifact Attestations ([docs](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)) generate cryptographically signed, in-toto-format attestations of artifact provenance, backed by Sigstore (public repos use the public-good instance, private repos use GitHub's private instance). For the SLSA build-track levels and what each requires, see the [SLSA build track](https://slsa.dev/spec/v1.0/levels#build-track).

## Achieving SLSA Build Levels Using Reusable Workflows

### Verification / cert-identity

Often the focus is put upon the "signing" of an artifact, but the source of value lies within [verifying artifacts](https://slsa.dev/spec/v1.0/verifying-artifacts). The [`gh attestation verify`](https://cli.github.com/manual/gh_attestation) command requires the path to a local or [OCI](https://opencontainers.org/) artifact plus an expected `--owner` or `--repo`. By default, the CLI does **not** check the `--signer-workflow` (a.k.a. `--cert-identity`) or the source ref — a missing `--cert-identity` flag is a real fail-open, since the artifact could have been built from a non-approved branch or by a non-approved workflow.

For autogov, supplying `--cert-identity` (the signer workflow) is **mandatory but on by default** in our reusable workflows: every verify job passes it, ensuring both the source repository and signer workflow originate from approved branches/tags (e.g. commit SHA) so the artifact is proven to meet SLSA Level 3 requirements — as long as whoever verifies remembers to include the flag.

gh-cli does not support verifying the source ref directly, so we combine `--jq` with `grep` on `sourceRepositoryRef`:

```yaml
- name: Verify Image Attestation(s)
  run: |
      set +x
      gh attestation verify \
        oci://${{ inputs.subject-name }}@${{ inputs.image-digest }} \
        --repo ${{ github.repository }} \
        --deny-self-hosted-runners \
        --cert-identity \
        "${{ inputs.cert-identity }}" \
        --format json \
        --jq '.[].verificationResult.signature.certificate.sourceRepositoryRef' \
      | grep "^${{ github.ref }}$"
```

The `cert-identity` input documents the requirement: if verifying an image the workflow name should be `rw-attest-image.yaml`; if verifying blob(s), `rw-attest-blob.yaml` (or `rw-attest-blob-offline.yaml` for the offline path).

### Certificate Identities

This repository maintains a `cert-identities.json` file that serves as the source of truth for valid certificate identities used by [autogov](https://github.com/liatrio/autogov). The file uses a flattened format with a single `identities` array, where each entry has a `status` field indicating whether it is:

- **latest**: Current reusable workflow identities at the current version
- **approved**: All approved workflow identities (includes previous valid versions)
- **revoked**: Identities that have been explicitly revoked and should not be used

Each identity consists of a version (e.g. `0.5.1`), a commit SHA, a `status`, an array of workflow identity URLs (including the tag's commit SHA), an addition date and optional expiration date, and revocation details if revoked.

When a new release is tagged, the release creates a tag pointing to a specific commit, and that tag's commit SHA is recorded in the identity entries. An automated workflow then updates `cert-identities.json` in a **separate** commit to `main` — the original tag remains pointing to its initial commit (intentionally). When consuming these workflows, reference them by their full identity URL with commit SHA rather than a branch ref, for immutability and security.

### Verification Using Cosign

You can also verify bundles with Sigstore's [cosign](https://github.com/sigstore/cosign) via `cosign verify-blob-attestation` (note: verifying images this way requires extra tooling such as regctl or Docker to fetch the OCI artifacts).

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

See [docs/verification-cosign.md](./docs/verification-cosign.md) for prerequisites (cosign install, trusted-root generation, ghcr.io login) and the regctl/Docker image-verification paths.

### Verification Using ORAS

You can use ORAS (OCI Registry As Storage) to inspect and verify artifact attestations — useful for understanding the relationship between image digests and their associated attestation layers. Discover the referrers (attestations) of an image:

```bash
oras discover ghcr.io/your-org/your-repo@<image_digest>
```

GitHub stores attestations **with** the container image in the OCI registry as additional manifests in the OCI index (not separately in GitHub's API); each attestation manifest carries the annotation `"vnd.docker.reference.type": "attestation-manifest"`.

In the attestation manifests you'll see different `artifactType` values for the different attestations:

- `application/vnd.dev.sigstore.bundle.v0.3+json`: Sigstore bundle format
- `https://slsa.dev/provenance/v1`: SLSA provenance attestation
- `https://autogov.dev/attestation/metadata/v1`: Metadata attestation
- `https://cyclonedx.org/bom`: SBOM attestation
- `https://in-toto.io/attestation/vulns/v0.2`: Vulnerabilities attestation
- `https://autogov.dev/attestation/source-review/v0.2`: Source-review (PR-approval + continuity) attestation

See [docs/oci-attestation-internals.md](./docs/oci-attestation-internals.md) for the OCI v1.1 Referrers API, full `oras manifest fetch` / `oras blob fetch` walkthroughs, the Sigstore bundle manifest shape, and Docker/regctl inspection notes.

### L3: Isolation of Build from Attest

To achieve [SLSA Build Level 3](https://slsa.dev/spec/v1.0/levels#build-l3-hardened-builds), builds and their artifacts must be isolated from one another so that other jobs cannot inadvertently or maliciously alter them. With GitHub Actions this means separating the signing process into its own job, running on GitHub's hardened runners (avoiding self-hosted runners), and abstracting build commands into a [Composite Action](https://docs.github.com/en/actions/sharing-automations/creating-actions/about-custom-actions#composite-actions) at a well-defined path. The reusable workflow runs the repository's local composite action to build an image or blob, then attests the artifacts in a separate attesting job.

![Job Isolation](./assets/isolated_attest_jobs.png)

To isolate job artifacts, the build job uploads the artifact(s) — or, for images, passes the image as a tarball between jobs — to the downstream attest/sign job. The [actions/upload-artifact](https://github.com/actions/upload-artifact) and [actions/download-artifact](https://github.com/actions/download-artifact) actions support immutable uploads/downloads via artifact IDs (the `artifact-ids` parameter), so the attest job is guaranteed to operate on the exact artifact, not one another job may have overwritten with the same name. The bundle and trusted-root are likewise passed as artifacts to enable [offline verification](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/verifying-attestations-offline) without extra permissions.

Passing artifacts between jobs also lets us **lower permissions**. The offline blob workflow (`rw-build-blob-offline.yaml`) needs no registry access:

```yaml
attest:
  permissions:
    id-token: write
    attestations: write
    packages: read
    contents: read
    actions: read
verify:
  permissions:
    contents: read
```

Otherwise (e.g. container-registry access for image builds) the following permissions are used:

```yaml
attest:
  permissions:
    id-token: write
    attestations: write
    packages: write
    contents: write
    actions: read
verify:
  permissions:
    id-token: write
    attestations: read
    packages: read
    contents: write
```

Note: the digest of an exported image tarball (`docker save`, uncompressed) will always differ from the digest of the pushed (compressed) registry image due to compression, per-layer digesting, and manifest metadata differences. To compare, match the individual layer digests rather than the overall image digest.

### L2: Ensure a Trusted Build Environment

To achieve [SLSA Build Level 2](https://slsa.dev/spec/v1.0/levels#build-l2-hosted-build-platform), builds must run on a hosted platform that generates and signs the provenance. Self-hosted runners [can be maliciously modified](https://docs.github.com/en/enterprise-cloud@latest/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#self-hosted-runner-security) by their host. Because a self-hosted runner can be labeled `ubuntu-latest`, the label alone is not enough — so we check the [runner context's](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/accessing-contextual-information-about-workflow-runs#runner-context) `runner.environment`, which is `github-hosted` for GitHub-hosted runners and `self-hosted` otherwise, and fail closed:

```yaml
- name: Fail if Runner is self-hosted
  if: ${{ runner.environment != 'github-hosted' }}
  run: |
      echo "Job is running on a self-hosted runner. Terminating job..."
      exit 1
```

Build steps additionally guard with `if: ${{ runner.environment == 'github-hosted' }}`. We also expose `--deny-self-hosted-runners` on the `gh attestation verify` calls. Offering control over the runner label (`runs-on: ${{ inputs.workflow-runner-label }}`) is acceptable leeway: the OS choice (`ubuntu-latest`, `macos-latest`, `windows-latest`) is [unambiguous](https://slsa.dev/spec/v1.0/requirements) even if not separately documented as provenance.

### L1: Documented Build Parameters

To achieve [SLSA Build Level 1](https://slsa.dev/spec/v1.0/levels#build-l1), the build steps must be consistent so that a verifier "forms expectations about what a 'correct' build" should look like. We check out the source repo by commit SHA rather than only by the ref of the calling workflow, mitigating [time-of-check-to-time-of-use (TOCTOU)](https://en.wikipedia.org/wiki/Time-of-check_to_time-of-use) scenarios where subsequent pushes land between trigger time and checkout:

```yaml
- name: Checkout code
  uses: actions/checkout@d632683dd7b4114ad314bca15554477dd762a938 # v4.2.0
  with:
    ref: ${{ github.sha }}
    persist-credentials: false
```

### Workflow Inputs and SLSA

SLSA's Provenance Spec requires `externalParameters` to be complete at Build L3 and MUST be included in provenance at L1. GitHub's build-provenance attestation omits workflow *inputs* — it records only `externalParameters.workflow` (path/ref/repository), `internalParameters`, and `resolvedDependencies`, not user-supplied inputs ([attest-build-provenance#55](https://github.com/actions/attest-build-provenance/issues/55), tracked upstream in [actions/toolkit#2331](https://github.com/actions/toolkit/issues/2331)). To close that gap and prevent [script-injection via non-recorded inputs](https://github.com/slsa-framework/slsa-github-generator/issues/3618#issuecomment-2105322454), autogov attests the workflow inputs (and other environment values) itself in a custom [metadata predicate](#tools-used) generated via `actions/attest`.

See [docs/slsa-workflow-inputs.md](./docs/slsa-workflow-inputs.md) for the full discussion, the metadata predicate shape, and the `gh attestation verify --jq | grep` patterns used to confirm specific inputs were recorded.

### Why No Pull Request?

`pull_request` events are **not** supported: the [SLSA GitHub Framework](https://github.com/slsa-framework/slsa-github-generator) treats them as untrusted because PR code can originate from a fork and modify the build environment or bypass checks. Restricting to `push`/`create`/`release` keeps builds in a controlled, trusted environment. If you would like `pull_request` support, the maintainers recommend reaching out via [slsa-github-generator issue #358](https://github.com/slsa-framework/slsa-github-generator/issues/358).

## Usage

### Tools Used

- [actions/attest](https://github.com/actions/attest) — generates SLSA build-provenance, the custom [cosign generic predicate](https://github.com/sigstore/cosign/blob/main/specs/COSIGN_PREDICATE_SPEC.md) (metadata), and SBOM attestations in the in-toto format (`actions/attest-build-provenance` is now a wrapper around it).
- [anchore/sbom-action](https://github.com/anchore/sbom-action) — generates a software bill of materials (SBOM) using Syft.
- [GitHub CLI `gh attestation`](https://cli.github.com/manual/gh_attestation) — verifies and downloads artifact attestations, online or offline.
- [OCI artifacts / OCI registries](https://opencontainers.org/) — store image attestations as additional content-addressable manifests linked to the image digest (`oci://` URIs, `permissions.packages`). See [OCI Image Format Spec](https://github.com/opencontainers/image-spec/tree/main?tab=readme-ov-file#oci-image-format-specification).
- [Sigstore](https://www.sigstore.dev/) — Rekor/Fulcio/Cosign provide the keyless signing and transparency log underneath GitHub Artifact Attestations.

![The OCI Design](./assets/oci_artifact_diagram.png)

When viewing your container images in GitHub Container Registry, you might notice additional digests that don't correspond to actual images — these are attestation manifests (metadata proving authenticity and provenance), inspectable via the [Verification Using ORAS](#verification-using-oras) section.

![Recent Tagged Image Versions](./assets/recent_tagged_image_versions.png)

![Additional Digest Example](./assets/additional_digest_example.png)

### Limiting Inputs by Wrapping Reusable Workflow Calls

It is good practice to wrap the actual call to each respective reusable workflow in an additional reusable workflow layer to limit the amount of inputs the user has access to (e.g. inputs for the verify jobs) which helps to circumvent script injection attacks.

### Access

#### Workflow Access

[Explicit workflow permissions](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#allowing-select-actions-and-reusable-workflows-to-run) can be set to only allow the "entrypoint" reusable workflows that call other reusable workflows.

Below are all of the GitHub Actions and Workflows that are permitted access in the caller workflow repo. The only reusable workflows not given direct access are `rw-<permissions_path>-attest-<build_type>.yaml`, `rw-<permissions_path>-verify.yaml`, and `rw-<permissions_path>-release.yaml`. Every entry needs the `@*` ref suffix (or a pinned ref) — a bare `owner/repo` matches nothing, which blocks the SHA-pinned action and causes a `startup_failure`:

```yaml
actions/attest@*,
actions/checkout@*,
actions/download-artifact@*,
actions/upload-artifact@*,
anchore/sbom-action@*,
anchore/scan-action@*,
docker/build-push-action@*,
docker/login-action@*,
docker/metadata-action@*,
docker/setup-buildx-action@*,
docker/setup-qemu-action@*,
octo-sts/action@*,
liatrio/autogov-workflows/.github/workflows/rw-build-blob.yaml@*,
liatrio/autogov-workflows/.github/workflows/rw-build-image.yaml@*,
liatrio/autogov-workflows/.github/workflows/rw-build-blob-offline.yaml@*,
```

It is also necessary to [allow access to workflows from other internal/private repositories](https://docs.github.com/en/enterprise-cloud@latest/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#allowing-access-to-components-in-an-internal-repository) to avoid having to provide further permissions with the fine grained personal access token discussed below.

#### Repository Access

> access is handled through Chainguard's Octo-STS (the recommended option) / an alternative is creating a [fine grained personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token) that has read permissions for the repository and [add the appropriate secret and environment variable(s)]([in the Secrets and Variables section for Actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)).

Basic read access can be provided using an `autogov-infra.sts.yaml` trust policy at the org level (under your org's `.github` repository), for example:

```yaml
issuer: https://token.actions.githubusercontent.com
subject_pattern: "repo:liatrio/.*"

permissions:
  contents: read

repositories:
  - your-policy-library
  - your-workflows
```

For any additional permissions, a local `*.sts.yaml` can be created. For example, the creation of the release tag uses the `.github/chainguard/release-ops.sts.yaml` file:

```yaml
issuer: https://token.actions.githubusercontent.com
subject_pattern: "repo:liatrio/<your-repo>:ref:refs/heads/main"
permissions:
  contents: write
  packages: write
```

More information about `octo-sts` can be found in the [octo-sts app](https://github.com/octo-sts/app) and the [octo-sts/action](https://github.com/octo-sts/action).

> **Bring your own auth**: `rw-verify.yaml` is consumer-configurable — set `octo-sts-scope` / `octo-sts-identity` (and, for cross-repo reads, `autogov-repo` / `policy-repo` / `cert-identities-repo`) to your own org and identities; leave `octo-sts-scope` empty to use `github.token` (the default, suitable for public repos). The `scope: liatrio` / `identity: autogov-infra` values shown in the other octo-sts examples are still liatrio-org-specific and hardcoded inside `rw-attest-*` (parameterizing those the same way is a tracked follow-up). External orgs must install their own octo-sts app and create equivalent trust policies.
>
> **Releases (`rw-release.yaml`)**: the binary download (read) and the release cut + asset upload (write) use separate octo-sts pairs.
>
> - Read: `octo-sts-read-scope` / `octo-sts-read-identity` (both default empty → `github.token`, suitable for public repos).
> - Write: `octo-sts-release-scope` / `octo-sts-release-identity` default to `liatrio` / `release-ops` so liatrio's release is unchanged. External orgs override these with their own scope and identity.
>
> If your release branch (e.g. `main`) is protected by a branch ruleset, the write actor MUST be on that ruleset's bypass list — `github.token` cannot bypass a branch ruleset, only an actor on the bypass list can. So external orgs with a protected main must (1) install their own octo-sts GitHub App, (2) add that App to the ruleset's bypass list, and (3) set `octo-sts-release-scope` / `octo-sts-release-identity` to a trust policy that issues `contents: write` for that App on the release branch. These same four inputs are threaded through `rw-build-image.yaml` / `rw-build-blob.yaml` / `rw-build-blob-offline.yaml` to the nested `rw-release` call.

### Inputs

> **Vulnerability thresholds** (the four `vuln-threshold-*` inputs) recur identically on `rw-build-image.yaml`, `rw-build-blob.yaml`, `rw-build-blob-offline.yaml`, `rw-verify.yaml`, and `rw-verify-offline.yaml`. They are defined once here and referenced below as **(vuln-threshold block)**:
>
> - `vuln-threshold-critical` (optional, string, default: '0'): Maximum critical vulnerabilities allowed (0=none, -1=unlimited).
> - `vuln-threshold-high` (optional, string, default: '0'): Maximum high vulnerabilities allowed (0=none, -1=unlimited).
> - `vuln-threshold-medium` (optional, string, default: '0'): Maximum medium vulnerabilities allowed (0=none, -1=unlimited).
> - `vuln-threshold-low` (optional, string, default: '0'): Maximum low vulnerabilities allowed (0=none, -1=unlimited).

#### `.github/actions/build-image/action.yaml`

- `subject-name` (required, string, default: '${{ github.repository }}'): Subject name as it should appear in the attestation.
- `github-token` (optional, string, default: ''): The GitHub token set throughout the reusable workflow including the composite (build) action.

#### `.github/actions/build-blob/action.yaml`

- No inputs for this action

#### `.github/workflows/rw-build-image.yaml`

- `subject-name` (required, string): Subject name as it should appear in the attestation.
- `registry` (required, string, default: 'ghcr.io'): Container registry to push image.
- `cert-identity` (required, string): The certificate identity of the signer workflow used in the verify job. The workflow name should be rw-attest-image.yaml.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use.
- `release-image` (optional, boolean, default: true): Whether to run the release-image job.
- `octo-sts-read-scope` / `octo-sts-read-identity` (optional, string, default: ''): octo-sts read pair threaded to the release job's autogov CLI download. Empty → `github.token`.
- `octo-sts-release-scope` / `octo-sts-release-identity` (optional, string, default: 'liatrio' / 'release-ops'): octo-sts write pair threaded to the release cut and asset upload. See `rw-release.yaml` for the branch ruleset bypass requirement.
- **(vuln-threshold block)**

#### `.github/workflows/rw-build-blob.yaml`

- `subject-path` (required, string): Path to the artifact serving as the subject of the attestation.
- `cert-identity` (required, string): The certificate identity of the signer workflow used in the verify job. The workflow name should be rw-attest-blob.yaml.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use.
- `release-blob` (optional, boolean, default: true): Whether to run the release-blob job.
- `octo-sts-read-scope` / `octo-sts-read-identity` (optional, string, default: ''): octo-sts read pair threaded to the release job's autogov CLI download. Empty → `github.token`.
- `octo-sts-release-scope` / `octo-sts-release-identity` (optional, string, default: 'liatrio' / 'release-ops'): octo-sts write pair threaded to the release cut and asset upload. See `rw-release.yaml` for the branch ruleset bypass requirement.
- **(vuln-threshold block)**

#### `.github/workflows/rw-build-blob-offline.yaml`

- `subject-path` (required, string): Path to the artifact serving as the subject of the attestation.
- `cert-identity` (required, string): The certificate identity of the signer workflow used in the verify job. The workflow name should be rw-attest-blob-offline.yaml.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use.
- `release-blob` (optional, boolean, default: true): Whether to run the release-blob job.
- `mutations-config` (optional, string, default: ''): Path to the mutations config file (e.g. .autogov-release.yaml) passed through to the release-blob job. Leave empty to skip mutations.
- `octo-sts-read-scope` / `octo-sts-read-identity` (optional, string, default: ''): octo-sts read pair threaded to the release job's autogov CLI download. Empty → `github.token`.
- `octo-sts-release-scope` / `octo-sts-release-identity` (optional, string, default: 'liatrio' / 'release-ops'): octo-sts write pair threaded to the release cut and asset upload. See `rw-release.yaml` for the branch ruleset bypass requirement.
- **(vuln-threshold block)**

#### `.github/workflows/rw-attest-image.yaml`

- `subject-name` (required, string): Subject name as it should appear in the attestation.
- `registry` (required, string, default: 'ghcr.io'): Container registry to push image.
- `show-summary` (optional, boolean, default: true): Whether to attach a list of generated attestations to the workflow run summary page.
- `workflow-runner-label` (optional, string, default: 'ubuntu-latest'): The label used for runner/OS selection.
- `github-token` (optional, string): The GitHub token set throughout the reusable workflow including the composite (build) action.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use for predicate generation.

#### `.github/workflows/rw-attest-blob.yaml`

- `subject-path` (required, string): Path to the artifact serving as the subject of the attestation.
- `blob-artifact-name` (optional, string, default: 'blob-build-artifact-high-perms'): The name of the artifact for the blob(s) built from the build-blob action.
- `show-summary` (optional, boolean, default: true): Whether to attach a list of generated attestations to the workflow run summary page.
- `workflow-runner-label` (optional, string, default: 'ubuntu-latest'): The label used for runner/OS selection.
- `github-token` (optional, string): The GitHub token set throughout the reusable workflow including the composite (build) action.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use.

#### `.github/workflows/rw-attest-blob-offline.yaml`

- `subject-path` (required, string): Path to the artifact serving as the subject of the attestation.
- `blob-artifact-name` (optional, string, default: 'blob-build-artifact-low-perms'): The name of the artifact for the blob(s) built from the build-blob action.
- `show-summary` (optional, boolean, default: true): Whether to attach a list of generated attestations to the workflow run summary page.
- `workflow-runner-label` (optional, string, default: 'ubuntu-latest'): The label used for runner/OS selection.
- `github-token` (optional, string): The GitHub token set throughout the reusable workflow including the composite (build) action.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use.

#### `.github/workflows/rw-verify.yaml`

- `build-type` (required, string): Specify the type of build: "image" or "blob".
- `subject-name` (optional, string, default: '${{ github.repository }}'): Subject name as it should appear in the attestation. Required unless subject-path is specified.
- `image-digest` (optional, string): The digest of the image that was built and pushed. Required for build-type "image".
- `registry` (optional, string, default: 'ghcr.io'): The container registry to use.
- `blob-artifact-id` (optional, string): The artifact-id of the build artifacts. Required for build-type "blob".
- `cert-identity` (required, string): The certificate identity of the signer workflow used in the verify job. The workflow name should be rw-attest-image.yaml for images, or rw-attest-blob.yaml for blob(s).
- `github-token` (optional, string, default: ''): The GitHub token set throughout the reusable workflow including the composite (build) action.
- `workflow-runner-label` (optional, string, default: 'ubuntu-latest'): The label of the workflow runner.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use (input name retained for backwards compatibility).
- `octo-sts-scope` (optional, string, default: ''): octo-sts scope for cross-repo reads (autogov binary, policy bundle, cert-identities). When empty, `github.token` is used (suitable for public repos); when set, the octo-sts token is used and is required (verification fails closed if the exchange fails).
- `octo-sts-identity` (optional, string, default: ''): octo-sts identity. Required when `octo-sts-scope` is set.
- `autogov-repo` (optional, string, default: 'liatrio/autogov'): Repository to download the autogov CLI release from.
- `policy-repo` (optional, string, default: 'liatrio/autogov-policy-library'): Repository providing the OPA policy bundle and schemas (consumed as `ghrel://<policy-repo>?asset=...`).
- `cert-identities-repo` (optional, string, default: 'liatrio/autogov-workflows'): Repository providing the cert-identities allowlist (`cert-identities.json`).
- `use-cert-identity-list` (optional, boolean, default: '${{ github.repository != 'liatrio/autogov-workflows' }}'): Whether to use cert-identity-list for validation.
- **(vuln-threshold block)**
- `policy-data-overlay` (optional, string, default: ''): Optional JSON merged over the generated vuln thresholds to enable per-repo gates such as `source_review_config` / `bypass_config` / `code_scan_thresholds`. Empty disables the overlay.

#### `.github/workflows/rw-verify-offline.yaml`

- `blob-artifact-id` (required, string): The artifact-id of the build artifacts.
- `attest-build-attestation-artifact-id` (optional, string): The artifact-id of the build provenance attestation artifact.
- `attest-metadata-attestation-artifact-id` (optional, string): The artifact-id of the custom metadata attestation artifact.
- `attest-sbom-attestation-artifact-id` (optional, string): The artifact-id of the SBOM attestation artifact.
- `attest-dependency-scan-attestation-artifact-id` (optional, string): The artifact-id of the dependency scan attestation artifact.
- `cert-identity` (required, string): The certificate identity of the signer workflow used in the verify job. The workflow name should be rw-attest-blob-offline.yaml.
- `github-token` (optional, string, default: ''): The GitHub token set throughout the reusable workflow including the composite (build) action.
- `workflow-runner-label` (optional, string, default: 'ubuntu-latest'): The label of the workflow runner.
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov version to use (input name retained for backwards compatibility).
- `cert-identities-repo` (optional, string, default: 'liatrio/autogov-workflows'): Repository providing the cert-identities allowlist (`cert-identities.json`).
- `use-cert-identity-list` (optional, boolean, default: '${{ github.repository != 'liatrio/autogov-workflows' }}'): Whether to use cert-identity-list (multi-signer allowlist) for validation. Mirrors the online verify default.
- **(vuln-threshold block)**
- `policy-data-overlay` (optional, string, default: ''): Optional JSON merged over the generated vuln thresholds to enable per-repo gates such as `source_review_config` / `bypass_config` / `code_scan_thresholds`. Empty disables the overlay.

#### `.github/workflows/rw-release.yaml`

- `branch` (optional, string, default: 'main'): Branch to cut the release from.
- `mutations-config` (optional, string, default: ''): Path to the mutations config file (e.g. .autogov-release.yaml).
- `dry-run` (optional, boolean, default: false): Run in dry-run mode (no commits, tags, or releases created).
- `autogov-version` (optional, string, default: 'v0.38.0'): The autogov release version to download and use.
- `vsa-artifact-id` (optional, string, default: ''): The artifact ID of the VSA to upload as a release asset.
- `blob-artifact-id` (optional, string, default: ''): Artifact ID of the blob to download and publish as a release asset.
- `workflow-runner-label` (optional, string, default: 'ubuntu-latest'): The label of the workflow runner.
- `github-token` (optional, string, default: ''): GitHub token for the binary download when `octo-sts-read-scope` is empty. Leave empty to use `github.token` (suitable for public repos).
- `octo-sts-read-scope` (optional, string, default: ''): octo-sts scope for the autogov CLI download (read). When empty, `github.token` is used (suitable for public repos).
- `octo-sts-read-identity` (optional, string, default: ''): octo-sts read identity. Required when `octo-sts-read-scope` is set.
- `octo-sts-release-scope` (optional, string, default: 'liatrio'): octo-sts scope for the write path (release cut commit/tag and asset upload). External orgs with a protected main override this with their own scope whose octo-sts app is on the branch ruleset bypass list.
- `octo-sts-release-identity` (optional, string, default: 'release-ops'): octo-sts write identity for the release cut and asset upload.

### Outputs

> **Attestation artifact IDs** — the following five outputs recur identically across the build/attest workflows. They are defined once here and referenced below as **(attest-artifact-id block)**:
>
> - `attest-build-attestation-artifact-id` (string): The artifact-id of the build provenance attestation artifact.
> - `attest-metadata-attestation-artifact-id` (string): The artifact-id of the custom metadata attestation artifact.
> - `attest-sbom-attestation-artifact-id` (string): The artifact-id of the SBOM attestation artifact.
> - `attest-dependency-scan-attestation-artifact-id` (string): The artifact-id of the dependency scan attestation artifact.
> - `attest-source-review-attestation-artifact-id` (string): The artifact-id of the source-review (PR-approval) attestation artifact.

#### `.github/actions/build-image/action.yaml`

- `image-digest` (string): The image digest of the image that was built from the build-image job.
- `subject-name-sanitized` (string): The sanitized (lowercase) subject name for OCI compliance. Use this value when referencing OCI image paths to ensure compliance with OCI naming requirements.

#### `.github/actions/build-blob/action.yaml`

- No outputs for this action

#### `.github/workflows/rw-build-image.yaml`

- **(attest-artifact-id block)**
- `image-digest` (string): The image digest of the image that was built.
- `vsa-artifact-id` (string): The artifact ID of the uploaded VSA.

#### `.github/workflows/rw-build-blob.yaml`

- **(attest-artifact-id block)**
- `blob-artifact-id` (string): The artifact-id of the blob artifact(s).
- `vsa-artifact-id` (string): The artifact ID of the uploaded VSA.

#### `.github/workflows/rw-build-blob-offline.yaml`

- **(attest-artifact-id block)** — except `attest-source-review-attestation-artifact-id`, which this workflow does not emit.
- `blob-artifact-id` (string): The artifact-id of the blob artifact(s).
- `vsa-artifact-id` (string): The artifact ID of the uploaded VSA.

#### `.github/workflows/rw-attest-image.yaml`

- `image-digest` (string): The image digest of the image that was built from the build-image job.
- **(attest-artifact-id block)**

#### `.github/workflows/rw-attest-blob.yaml`

- `blob-artifact-id` (string): The artifact-id of the blob artifact(s).
- **(attest-artifact-id block)**

#### `.github/workflows/rw-attest-blob-offline.yaml`

- `blob-artifact-id` (string): The artifact-id of the blob artifact(s).
- **(attest-artifact-id block)** — except `attest-source-review-attestation-artifact-id`, which this workflow does not emit.

#### `.github/workflows/rw-verify.yaml`

- `vsa-artifact-id` (string): The artifact ID of the uploaded VSA.

#### `.github/workflows/rw-verify-offline.yaml`

- `vsa-artifact-id` (string): The artifact-id of the VSA attestation artifact.

#### `.github/workflows/rw-release.yaml`

- `version` (string): The version of the release that was cut.
- `tag` (string): The tag created for the release.
- `commit-sha` (string): The SHA of the release commit.
- `commit-verified` (string): Whether the release commit is verified.

### Example Workflow Snippets

An end-to-end pipeline wires the build (entrypoint), attest, verify, and release jobs together. The entrypoint `rw-build-*` workflows call the matching `rw-attest-*` internally; the snippets below show how a caller chains the jobs explicitly:

```yaml
jobs:
  # 1. build + attest (use rw-build-image / rw-build-blob / rw-build-blob-offline)
  attest-image:
    permissions:
      id-token: write
      attestations: write
      packages: write
      contents: write
    uses: liatrio/autogov-workflows/.github/workflows/rw-attest-image.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
    secrets: inherit
    with:
      subject-name: ${{ github.repository }}
      registry: ghcr.io

  # 2. verify -> emits the gating VSA
  verify-image:
    permissions:
      id-token: write
      attestations: read
      packages: read
    needs: [attest-image]
    uses: liatrio/autogov-workflows/.github/workflows/rw-verify.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
    secrets: inherit
    with:
      build-type: image
      image-digest: ${{ needs.attest-image.outputs.image-digest }}
      cert-identity: https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-image.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release

  # 3. release -> cuts the release attaching the VSA + blob assets
  release-image:
    permissions:
      contents: write
      id-token: write
      actions: read
    needs: [verify-image, attest-image]
    uses: liatrio/autogov-workflows/.github/workflows/rw-release.yaml@<commit_sha> # <semver> / a commit SHA from an official autogov-workflows release
    secrets: inherit
    with:
      mutations-config: .autogov-release.yaml
      vsa-artifact-id: ${{ needs.verify-image.outputs.vsa-artifact-id }}
```

For blob builds, swap `rw-attest-image.yaml` → `rw-attest-blob.yaml` (or `rw-attest-blob-offline.yaml`), set `build-type: blob`, and pass `blob-artifact-id: ${{ needs.attest-blob.outputs.blob-artifact-id }}` (plus the `attest-*-attestation-artifact-id` outputs to `rw-verify-offline.yaml` for the offline path) instead of `image-digest`.

#### Automating Version Updates

To update files as part of a release (e.g. version bumping a Dockerfile, manifests, or config), add a `.autogov-release.yaml` mutations file to your repository root and pass it to the release workflow via `mutations-config` (see the caller example above). On release, `autogov release cut` applies the mutations, commits the changed files in the `chore(release)` commit, and tags the new version.

Each mutation has a `path`, a `type`, and a `field`; `${version}` expands to the new release version. Supported types:

- `jsonPath` — set a field in a JSON file (`field` is the key, e.g. `version`).
- `yamlPath` — set a field in a YAML file (`field` is the key, e.g. `version` or `appVersion`).
- `regexReplace` — replace a regex match (`field` is the pattern, `replace` is the replacement template).
- `exec` — run a command (`field` is the command).

A mutations file can combine types — for example, a `regexReplace` version bump and an `exec` regeneration:

```yaml
mutations:
  - path: Dockerfile
    type: regexReplace
    field: 'ENV VERSION="[^"]*"'
    replace: 'ENV VERSION="${version}"'
  - path: cert-identities.json
    type: exec
    field: './scripts/update-cert-identities.sh ${version}'
```

For multiple files, add a rule per file, or use an `exec` mutation (e.g. `find . -name '*.yaml' -exec sed -i 's/version: .*/version: ${version}/' {} \;`).

## Troubleshooting

### Common Issues

1. **Permission Denied**:
   Ensure that your PAT and respective workflows have the necessary [access](#access).

2. **Workflow Fails to Trigger**:
   Check that you are using one of the supported event types: `create`, `release`, `push`, or `workflow_dispatch`.

3. **Attestation Verification Fails**:
   Ensure that the `cert-identity` and other inputs are correctly specified. Verify that the workflow is running on GitHub-hosted runners.

To debug GitHub environment variables (owner, repository, etc.), dump the contexts in a step. A `printenv | grep '^GITHUB_'` or echoing `toJson(github)` / `toJson(runner)` into an `env:` block then `echo`-ing it is usually enough; the `inputs` context (`toJson(inputs)`) is the one to dump when checking workflow inputs.

### Getting Help

If you encounter any issues not covered here, please open an issue on our [GitHub repository](https://github.com/liatrio/autogov-workflows/issues).

## Additional Resources

- [docs/verification-cosign.md](./docs/verification-cosign.md) — verifying attestations with Sigstore cosign (prerequisites + image paths).
- [docs/oci-attestation-internals.md](./docs/oci-attestation-internals.md) — OCI v1.1 Referrers API and inspecting attestation manifests with ORAS.
- [docs/slsa-workflow-inputs.md](./docs/slsa-workflow-inputs.md) — how autogov records workflow inputs to satisfy SLSA build-level requirements.
- [Sigstore Rekor](https://github.com/sigstore/rekor) — transparency log of signed metadata.
- [Sigstore Fulcio](https://github.com/sigstore/fulcio) — keyless certificate authority for OIDC identities.
- [Sigstore Cosign](https://github.com/sigstore/cosign) — signing and verifying images and artifacts.
- [Why is Github Artifact Attestations Considered SLSA Build L2+ and not SLSA Build L3?](https://www.ianlewis.org/en/understanding-github-artifact-attestations)
- [Trusted Builder and Provenance Generator Specifications](https://github.com/slsa-framework/slsa-github-generator/blob/3d34abbe34b268bb6c02651df2117370e8cee1bd/SPECIFICATIONS.md#trusted-builder-and-provenance-generator)
- [Hardening Requirements](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#hardening)
- [Best SDLC Practices](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#best-sdlc-practices)
- [Build Your Own Builder (BYOB) Framework](https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#build-your-own-builder-byob-framework)
- [Provenance Build Definition](https://slsa.dev/spec/v1.0/provenance#BuildDefinition)
- [Provenance Model/Schema](https://slsa.dev/spec/v1.0/provenance#model)

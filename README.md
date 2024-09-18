# Reusable Workflows using GitHub Artifact Attestations

simply using reusable workflows is not enough to achieve slsa build L3 using via gh's artifact attestation offering; this investigation will be an attempt to document what it takes for our reusable workflows and their implementation to truly achieve lvl 3 of slsa / tampering during the build:

check for the following:

- [unambiguous instructions for how to initiate the build given this BuildDefinition](https://slsa.dev/spec/v1.0/provenance#BuildDefinition) /[github wf build type example](https://github.com/slsa-framework/github-actions-buildtypes/tree/main/workflow/v1)
- changes that were not approved
- self-hosted runners
- exposed secret signing material
i believe there is further we can do to ensure we're checking for these specific items above (e.g. we're not inherently checking is we're running on self-hosted runners before attesting, that's something we'll want to add).

further info on L3 slsa requirements:

## hardening verification

sadly, gh-cli does not support verifying the source branch / we have an alternative to this (e.g not simply relying on the repo). will discuss

- avoid the use of regex for --cert-identity

notes:

policy:
the workflow name (e.g. attest-blah.yml) should be checked against the wf_ref in the attestation/predicate and that should be the check on if a certain attestation (e.g. sbom, build_prov, generic/metadata) should exist.

keep these things in mind:

Permissions: Ensure the workflow has the necessary permissions, such as id-token: write and attestations: write.
Batch Processing: For actions/attest, subjects are processed in batches to avoid overwhelming the attestation API.
Predicate Size Limits: Both actions/attest and actions/attest-sbom have a maximum predicate size limit of 16MB.

[If you use a GitHub-hosted runner, each job runs in a fresh instance of a runner image specified by runs-on.](https://docs.github.com/en/actions/writing-workflows/choosing-where-your-workflow-runs/choosing-the-runner-for-a-job#choosing-github-hosted-runners)

the build job (e.g. either image-build or blob-build) require nothing and are not dependent on any other jobs.

slsa-framework:

- <https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#build-your-own-builder-byob-framework>

hardening reqs:

- <https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#hardening>

sdlc practices:

Best SDLC Practices
It is important you follow best development practices for your code, including your TRW, TCA and existing Action. In particular:

Harden your CI, e.g., set your top-level workflow permissions to read-only.
Pin your depenencies by hash except the delegator workflow, to avoid dependency confusion attacks and speed up incidence response.
If you download binaries, verify their SLSA provenance before running them. Use the installer action to install and use slsa-verifier.
Install or use a tool like OSSF Scorecard to verify you're comprehensively looking at your SDLC.

- <https://github.com/slsa-framework/slsa-github-generator/blob/main/BYOB.md#best-sdlc-practices>

specs:

- <https://github.com/slsa-framework/slsa-github-generator/blob/3d34abbe34b268bb6c02651df2117370e8cee1bd/SPECIFICATIONS.md#trusted-builder-and-provenance-generator>

gh attestation cmd:

- <https://cli.github.com/manual/gh_attestation>

attestation actions used:

- <https://github.com/actions/attest-build-provenance>
- <https://github.com/actions/attest>
- <https://github.com/actions/attest-sbom>

# A Note About SLSA's Build Level Requirements for Recording/Attesting to Workflow Inputs

How autogov-workflows records and attests to user workflow inputs to stay compliant across all SLSA Build Levels.

Part of the [autogov-workflows](../README.md) docs.

We use the [actions/attest](https://github.com/actions/attest) GitHub Action to generate build provenance attestations for workflow artifacts. This action binds a named artifact along with its digest to a SLSA build provenance predicate using the in-toto format. The action does not [document or save workflow inputs](https://github.com/actions/attest-build-provenance/issues/55), but as the issue points out, SLSA's Build L3 can be summarized as isolation between the builder and signer environments though SLSA's Provenance Spec does touch on `externalParameters`. While it may be somewhat ambiguous if they are necessary for [Level 2](https://slsa.dev/spec/v1.0/levels#build-l2-hosted-build-platform) or for [Level 3](https://slsa.dev/spec/v1.0/levels#build-l3-hardened-builds), [Level 1](https://slsa.dev/spec/v1.0/levels#build-l1) is not ambiguous and specifically states the following:

[The SLSA Provenance Model](https://slsa.dev/spec/v1.0/provenance#model)
> externalParameters: the external interface to the build. In SLSA, these values are untrusted; they MUST be included in the provenance and MUST be verified downstream.

[The SLSA Provenance Build Definition](https://slsa.dev/spec/v1.0/provenance#builddefinition)
> The parameters that are under external control, such as those set by a user or tenant of the build platform. They MUST be complete at SLSA Build L3, meaning that there is no additional mechanism for an external party to influence the build. (At lower SLSA Build levels, the completeness MAY be best effort.)

 One of the main reasons to attest to workflow inputs on GitHub's platform is to avoid [script injection attacks](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#example-of-a-script-injection-attack), that is, a maintainer could ["obfuscate the code used to build their artifact by using a malicious (non-recorded) input"](https://github.com/slsa-framework/slsa-github-generator/issues/3618#issuecomment-2105322454).

There is also [further discussion in slsa-github-generator#3618](https://github.com/slsa-framework/slsa-github-generator/issues/3618) where the maintainers of SLSA's slsa-github-generator state that workflow inputs must be included during the attestation generation stage:

- There is a [need to record inputs](https://github.com/slsa-framework/slsa-github-generator/issues/3618#issuecomment-2105994775) from the repository workflow including:
  - Workflow input(s)
  - Variables (e.g. user inputted environment vars / `env.*`)
  - GitHub event(s)

The maintainers of the [SLSA Framework](https://github.com/slsa-framework) just recently included workflow inputs in the [slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator):

- [feat: Record vars in SLSA generators](https://github.com/slsa-framework/slsa-github-generator/commit/40c607fde64a75eaaa47a6e41e674011d96060f1)

Currently, only the following is provided from GitHub's Build Provenance Attestation:

- `externalParameters`: This includes details about the workflow (workflow key) like its path, reference (ref), and repository. This is considered a top-level input as it directly defines the configuration of the workflow used in the build.
- `internalParameters`: These are specific to the GitHub-hosted runner environment, such as `event_name`, `repository_id`, `repository_owner_id`, and `runner_environment`. They provide information about the context in which the build was run, but they are typically not explicitly set by a user. Instead, they are collected automatically from the GitHub Actions runtime.
- `resolvedDependencies`: This lists dependencies used during the build, including a `gitCommit` digest that points to a specific version of the source code. This ensures reproducibility by tying the build to an exact version of the source.

- `gh attestation verify oci://<subject_name>@<image_digest> --repo <repo> --cert-identity "<signer_workflow>@<github_ref>" --format json --jq '.[].verificationResult.statement.predicate.buildDefinition'`:

```json
{
  "buildType": "https://actions.github.io/buildtypes/workflow/v1",
  "externalParameters": {
    "workflow": {
      "path": ".github/workflows/cw-check.yaml",
      "ref": "<github.ref>",
      "repository": "https://github.com/liatrio/autogov-workflows"
    }
  },
  "internalParameters": {
    "github": {
      "event_name": "release",
      "repository_id": "849445664",
      "repository_owner_id": "5726618",
      "runner_environment": "github-hosted"
    }
  },
  "resolvedDependencies": [
    {
      "digest": {
        "gitCommit": "<git.sha>"
      },
      "uri": "git+https://github.com/liatrio/autogov-workflows@<github.ref>"
    }
  ]
}
```

While the slsa-github-generator ["...can record the inputs in a trustworthy way", "..the GitHub artifact attestations currently cannot."](https://github.com/slsa-framework/slsa-github-generator/issues/3618#issuecomment-2106479658) Essentially, GitHub would need to provide workflow inputs in the build provenance attestation using something like `buildDefinition.externalParameters.workflow.inputs` instead of just `path`, `ref`, and `repository`.

To be compliant across all SLSA Build Levels, we satisfy this gap in GitHub's artifact attestations offering ourselves by including workflow inputs, as well as other environment variable values, in our [generic metadata predicate/attestation](../README.md#tools-used) (discussed further below under the [tools section](../README.md#tools-used)) that we attest to using the `actions/attest` action.

An example of our metadata predicate:

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "metadata": {
    "workflowData": {
      "workflowRefPath": "${{ github.workflow_ref }}",
      "branch": "${{ github.ref_name }}",
      "buildWorkflowRunId": "${{ github.run_id }}",
      "event": "${{ github.event_name }}",
      "inputs": "${{toJson(inputs)}}"
    },
    "commitData": {
      "commitSHA": "${{ github.sha }}",
      "commitTimestamp": "${{ github.event.head_commit.timestamp }}"
    },
    "repositoryData": {
      "repository": "${{ github.repository }}",
      "repositoryId": "${{ github.repository_id }}",
      "githubServerURL": "${{ github.server_url }}"
    },
    "ownerData": {
      "owner": "${{ github.repository_owner }}",
      "ownerId": "${{ github.repository_owner_id }}"
    },
    "jobData": {
      "jobId": "${{ github.job }}",
      "runNumber": "${{ github.run_number }}",
      "action": "${{ github.action }}",
      "actor": "${{ github.actor }}",
      "status": "${{ job.status }}"
    },
    "runnerData": {
      "os": "${{ runner.os }}",
      "name": "${{ runner.name }}",
      "arch": "${{ runner.arch }}",
      "environment": "${{ runner.environment }}"
    }
  }
}
```

The `inputs` object is used to hydrate the metadata artifact/attestation and then the following `gh attestation verify` commands are used to verify those inputs exist.

image:

```shell
gh attestation verify \
  oci://${{ inputs.subject-name }}@${{ inputs.image-digest }} \
  --repo ${{ github.repository }} \
  --deny-self-hosted-runners \
  --cert-identity \
  "${{ inputs.cert-identity }}" \
  --format json \
  --jq '.[].verificationResult | {keys: (.statement.predicate.metadata.workflowData.inputs // {}) | keys}' \
| grep -E \
  'subject-name|registry|workflow-runner-label|show-summary' | \
  jq -r
```

blob:

```shell
find "$ARTIFACTS_FOLDER" -type f | while read -r ARTIFACT; do
  gh attestation verify \
    $ARTIFACT \
    --deny-self-hosted-runners \
    --repo ${{ github.repository }} \
    --cert-identity "${{ inputs.cert-identity }}" \
    --format json \
    --jq '.[].verificationResult | {keys: (.statement.predicate.metadata.workflowData.inputs // {}) | keys}' \
  | grep -E \
    'blob-artifact-name|subject-path|workflow-runner-label|show-summary' | \
  jq -r
done
```

Instead of moving forward with the expectation that `externalParameters.workflow` and the `resolvedDependencies` (e.g. considered top-level inputs since they directly impact the build and are part of what makes the build traceable, but not necessarily reproducible) are sufficient in meeting all of SLSA's Build Level requirements, we are going one step further by including user inputs using our "custom predicate".

For the time being, our solution provides a stop gap until GitHub offers a native solution as per the issue above, [feat: include workflow inputs in externalParameters](https://github.com/actions/attest-build-provenance/issues/55), to record/attest to user workflow inputs.

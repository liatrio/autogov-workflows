# Verification Using ORAS

A deep-dive into OCI attestation internals: the v1.1 Referrers API, how GitHub stores attestations alongside images, and how to inspect attestation manifests and layers with ORAS.

Part of the [autogov-workflows](../README.md) docs.

In addition to using Cosign and the GitHub CLI, you can use ORAS (OCI Registry As Storage) commands to inspect and verify artifact attestations. This is particularly useful for understanding the relationship between image digests and their associated attestation layers.

## Understanding OCI Layers and Attestations

When working with container images and their attestations in an OCI registry, you might notice additional digests that don't seem to correspond to an actual image. These are typically artifact manifests containing attestations. Here's how to inspect them:

1. First, install ORAS:

```bash
# Using Homebrew
brew install oras-cli

# Or download from GitHub releases
# Visit: https://github.com/oras-project/oras/releases
```

2. Use ORAS to discover referrers (attestations) of an image:

```bash
oras discover ghcr.io/your-org/your-repo@<image_digest>
```

## OCI v1.1 and the Referrers API

The [OCI Image and Distribution Specs v1.1](https://opencontainers.org/posts/blog/2024-03-13-image-and-distribution-1-1) introduced significant improvements for artifact management, including the **Referrers API** which provides a standardized way to discover artifacts associated with container images.

**Key Features:**

- **Subject Field**: Manifests can now include a `subject` field to define associations with other manifests (used for signatures, attestations, and metadata)
- **Referrers API**: New endpoint `GET /v2/<name>/referrers/<digest>` returns an OCI Index listing all manifests that reference a specific digest
- **Artifact Type**: Enhanced `artifactType` field enables better artifact classification without requiring dedicated `config.mediaType` values

**Example Referrers API Response:**

```bash
GET /v2/<name>/referrers/sha256:21edd7d11800e94bae9f4...
```

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9e6569b15e5ed981334003eb8...",
      "size": 724,
      "annotations": {
        "org.opencontainers.image.created": "2024-03-02T15:16:17Z",
        "org.opencontainers.image.description": "Example artifact for image sha256:21ed..."
      },
      "artifactType": "application/example"
    }
  ]
}
```

The Referrers API allows tooling to select desired artifacts from the OCI Index using `artifactType` and `annotation` values, similar to how runtimes use platform information to select images from multi-platform indexes.

## GitHub Attestation Storage Method

GitHub stores attestations **with** the container image in the OCI registry as additional manifests in the OCI index, not separately in GitHub's API. Each attestation manifest has the annotation `"vnd.docker.reference.type": "attestation-manifest"`.

## Example: Discovering GitHub Attestations

```bash
# Discover attestations attached to an image
❯ oras discover ghcr.io/liatrio/autogov-workflows:latest --artifact-type application/vnd.in-toto+json
ghcr.io/liatrio/autogov-workflows@sha256:8c99eaaec2af1b96833bf7b7294cc8c418647a9c8cbc50610220d21224e11f7e

# Fetch the OCI index manifest to see all components
❯ oras manifest fetch ghcr.io/liatrio/autogov-workflows@sha256:8c99eaaec2af1b96833bf7b7294cc8c418647a9c8cbc50610220d21224e11f7e | jq .
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:b4a5d4413b447e480ea21e7b5d268b1e3aa35915fbbc04e81b3d1a1f66e7e8d0",
      "size": 1436,
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:769cad7f0ad8f17c00c286310435817967a8042c0041fcf424bd9e275222338a",
      "size": 566,
      "annotations": {
        "vnd.docker.reference.digest": "sha256:b4a5d4413b447e480ea21e7b5d268b1e3aa35915fbbc04e81b3d1a1f66e7e8d0",
        "vnd.docker.reference.type": "attestation-manifest"
      },
      "platform": {
        "architecture": "unknown",
        "os": "unknown"
      }
    }
  ]
}

# Fetch the specific attestation manifest
❯ oras manifest fetch ghcr.io/liatrio/autogov-workflows@sha256:769cad7f0ad8f17c00c286310435817967a8042c0041fcf424bd9e275222338a | jq .
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:859ef09df31ef1ccf832323fb95f17c14b2fdbaa092056c95768c78f1c0aa05e",
    "size": 167
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:eaeadb461c5f7f9157bde556387872d8cf1748eb53038c6464c45cbd43eb44ef",
      "size": 1876,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}

# Retrieve the actual attestation content
❯ oras blob fetch ghcr.io/liatrio/autogov-workflows@sha256:eaeadb461c5f7f9157bde556387872d8cf1748eb53038c6464c45cbd43eb44ef --output attestation.json
❯ cat attestation.json | jq .
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "subject": [
    {
      "name": "pkg:docker/ghcr.io/liatrio/autogov-workflows@latest?platform=linux%2Famd64",
      "digest": {
        "sha256": "b4a5d4413b447e480ea21e7b5d268b1e3aa35915fbbc04e81b3d1a1f66e7e8d0"
      }
    }
  ],
  "predicate": {
    "builder": {
      "id": "https://github.com/liatrio/autogov-workflows/actions/runs/17273134791/attempts/1"
    },
    "buildType": "https://mobyproject.org/buildkit@v1",
    "metadata": {
      "https://mobyproject.org/buildkit@v1#metadata": {
        "vcs": {
          "revision": "0ba88277d047a99f4929d3e1ae33279e161489a1",
          "source": "https://github.com/liatrio/autogov-workflows"
        }
      }
    }
  }
}
```

For example, examining attestations for our policy library image:

```bash
❯ oras manifest fetch ghcr.io/liatrio/autogov-policy-library:sha256-d3e372efc3aa38f81c1d7c30b1cb9d77195c6f6456cced7a3b36f333ee220492 | jq -r
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "schemaVersion": 2,
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:ec4898a09dd73d59882d82c3b02cd78e9ce471ccf3f28472563c9b250d1964e9",
      "size": 814,
      "artifactType": "application/vnd.dev.sigstore.bundle.v0.3+json",
      "annotations": {
        "org.opencontainers.image.created": "2025-01-24T20:47:58.951Z",
        "dev.sigstore.bundle.content": "dsse-envelope",
        "dev.sigstore.bundle.predicateType": "https://slsa.dev/provenance/v1"
      }
    },
    // ... other attestation layers ...
  ]
}
```

Example of Sigstore Bundle Attestation / `application/vnd.dev.sigstore.bundle.v0.3+json`:

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "artifactType": "application/vnd.dev.sigstore.bundle+json;version=0.2",
  "config": {
    "mediaType": "application/vnd.oci.empty.v1+json",
    "digest": "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    "size": 2
  },
  "layers": [
    {
      "mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.2",
      "digest": "sha256:4bd9df17d3cfa8632690f6251b7dc6d2f7cebd60313c49bea4092b9489e2d4a4",
      "size": 4967
    }
  ],
  "subject": {
    "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    "digest": "sha256:010511b82573da0735bbbc09ab0b1b9e9218732306d96b81beb694cfe431a499",
    "size": 523
  }
}
```

- `artifactType` defines the Sigstore bundle's media type, useful for registry compatibility.
- The `config` section uses an empty configuration (`application/vnd.oci.empty.v1+json`) since the bundle doesn't need specific configuration data.
- The `layers` array holds the Sigstore bundle content, with its size and hash.
`subject` points to the associated artifact or image that the Sigstore bundle attests to, linking it with its own media type and digest.

## Important Notes About Attestation Layers

1. **Image Manifests**: You can use a variety of tools to inspect the actual image manifest such as Docker:

```bash
❯ docker manifest inspect ghcr.io/your-org/your-repo:sha256-<attestation_digest>
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.oci.image.index.v1+json",
   "manifests": [
      {
...
      }
   ]
}
```

But, if you try to pull an unsupported OCI artifact via Docker you'll get:

```bash
❯ docker pull ghcr.io/your-org/your-repo:sha256-<attestation_digest>
sha256-<attestation_digest>: Pulling from <repo>>
unsupported media type application/vnd.oci.empty.v1+json
```

2. **Attestation Manifests**: The additional digests you see in the registry that don't correspond to actual images are artifact manifests containing attestations. While these won't be visible through standard Docker commands, they can be inspected using ORAS:

```bash
# This will fail as it's an attestation manifest, not an image
❯ docker inspect ghcr.io/your-org/your-repo:sha256-<attestation_digest>
[]
Error: No such object

# Use ORAS instead to discover attestation relationships
❯ oras discover ghcr.io/your-org/your-repo:sha256-<attestation_digest>
```

3. **Layer Types**: In the manifest, you'll notice different `artifactType` values corresponding to different attestations:
   - `application/vnd.dev.sigstore.bundle.v0.3+json`: Sigstore bundle format
   - `https://slsa.dev/provenance/v1`: SLSA provenance attestation
   - `https://autogov.dev/attestation/metadata/v1`: Metadata attestation
   - `https://cyclonedx.org/bom`: SBOM attestation
   - `https://in-toto.io/attestation/vulns/v0.2`: Vulnerabilities attestation
   - `https://autogov.dev/attestation/source-review/v0.2`: Source-review (PR-approval + continuity) attestation

For more detailed information about ORAS commands and capabilities, refer to the [ORAS documentation](https://oras.land/docs/commands/oras_discover/).

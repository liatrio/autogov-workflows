#!/bin/bash
set -e

# updates the certificate identities file, cert-identities.json.

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "Error: No version provided"
  echo "Usage: $0 <version>"
  exit 1
fi

# dependency check
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed"
  echo "Please install jq: https://stedolan.github.io/jq/download/"
  exit 1
fi

echo "Updating certificate identities for version $VERSION"

echo "Processing workflow files for cert-identities.json..."
RW_FILES=$(find .github/workflows -name "rw-*-attest-*.yaml" -o -name "rw-*-attest-*.yml" -type f)

if [ -z "$RW_FILES" ]; then
  echo "No reusable workflow files found"
  exit 0
fi

# get current commit sha
COMMIT_SHA=$(git rev-parse HEAD)
TODAY=$(date +%Y-%m-%d)
EXPIRY_DATE=$(date -d "+1 year" +%Y-%m-%d)

# create temp file
cp cert-identities.json cert-identities.tmp.json

for FILE in $RW_FILES; do
  # get wf names
  FILENAME=$(basename "$FILE")
  WF_NAME=$(echo "$FILENAME" | sed 's/\.ya\?ml$//')

  # check if hp or lp
  if [[ "$WF_NAME" == *"hp"* ]]; then
    PRIVILEGE="High privilege"
  else
    PRIVILEGE="Low privilege"
  fi

  # define wfs
  PURPOSE=""
  if [[ "$WF_NAME" == *"attest-image"* ]]; then
    PURPOSE="attesting container images"
  elif [[ "$WF_NAME" == *"attest-blob"* ]]; then
    PURPOSE="attesting blob artifacts"
  elif [[ "$WF_NAME" == *"run-opa"* ]]; then
    PURPOSE="running OPA policies"
  elif [[ "$WF_NAME" == *"verify"* ]]; then
    PURPOSE="verification"
  elif [[ "$WF_NAME" == *"build-image"* ]]; then
    PURPOSE="building container images"
  elif [[ "$WF_NAME" == *"build-blob"* ]]; then
    PURPOSE="building blob artifacts"
  elif [[ "$WF_NAME" == *"release"* ]]; then
    PURPOSE="releasing artifacts"
  else
    PURPOSE="general automation"
  fi

  # cert-id w/ commit sha
  IDENTITY="https://github.com/liatrio/liatrio-gh-autogov-workflows/$FILE@$COMMIT_SHA"

  DISPLAY_NAME=$(echo "$WF_NAME" | tr '[:lower:]' '[:upper:]' | sed 's/RW-//')
  ENTRY_NAME="$DISPLAY_NAME v$VERSION"
  DESCRIPTION="$PRIVILEGE workflow for $PURPOSE (latest stable release)"

  echo "Processing $ENTRY_NAME ($IDENTITY)"

  # get wf path w/o commit sha
  WORKFLOW_PATH=$(echo "$IDENTITY" | cut -d '@' -f 1)

  # move previous latest versions to approved before adding new latest
  jq \
    --arg workflow_path "$WORKFLOW_PATH" \
    '.approved = (if .approved then .approved else [] end) |
     .latest = (if .latest then .latest else [] end) |
     # move previous versions of this workflow from latest to approved
     .approved = (.latest | map(select((.identity | split("@")[0]) == $workflow_path))) + .approved' \
    cert-identities.tmp.json >cert-identities.tmp2.json

  mv cert-identities.tmp2.json cert-identities.tmp.json

  # update latest with new version / remove old versions
  jq \
    --arg name "$ENTRY_NAME" \
    --arg identity "$IDENTITY" \
    --arg description "$DESCRIPTION" \
    --arg added "$TODAY" \
    --arg expires "$EXPIRY_DATE" \
    --arg workflow_path "$WORKFLOW_PATH" \
    '.latest = (if .latest then .latest else [] end) | 
     # removes previous entries from latest
     .latest = (.latest | map(select((.identity | split("@")[0]) != $workflow_path))) |
     # adds new entry to latest
     .latest = [{"name": $name, "identity": $identity, "description": $description, "added": $added, "expires": $expires}] + .latest' \
    cert-identities.tmp.json >cert-identities.tmp2.json

  mv cert-identities.tmp2.json cert-identities.tmp.json
done

# updates metadata
jq \
  --arg last_updated "$TODAY" \
  --arg version "v$VERSION" \
  --arg maintainer "@liatrio/tag-autogov" \
  '.metadata = {"last_updated": $last_updated, "version": $version, "maintainer": $maintainer}' \
  cert-identities.tmp.json >cert-identities.tmp2.json

mv cert-identities.tmp2.json cert-identities.tmp.json

# format json / update cert-identities.json
jq . cert-identities.tmp.json >cert-identities.json
rm cert-identities.tmp.json

echo "Successfully updated certificate identities for version $VERSION"

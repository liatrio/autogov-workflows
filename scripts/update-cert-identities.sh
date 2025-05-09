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

# get the commit sha tag points to, we want to use the tag's original commit sha,
# not the sha of the commit that will be created by this update
if [ -z "$COMMIT_SHA" ]; then
  echo "Getting commit SHA for tag $VERSION"
  COMMIT_SHA=$(git rev-list -n 1 "$VERSION" 2>/dev/null)

  # tag should always exist
  if [ -z "$COMMIT_SHA" ]; then
    echo "ERROR: Could not find tag $VERSION. Aborting certificate identity update."
    exit 1
  fi
else
  echo "Using provided commit SHA from environment: $COMMIT_SHA"
fi

echo "Using commit SHA: $COMMIT_SHA for version $VERSION"
TODAY=$(date +%Y-%m-%d)

# get expiration date (1 year from now) - support macos/ubuntu formats
if date -d "+1 year" +%Y-%m-%d &>/dev/null; then
  # ubuntu/linux format
  EXPIRY_DATE=$(date -d "+1 year" +%Y-%m-%d)
else
  # macos format
  EXPIRY_DATE=$(date -v+1y +%Y-%m-%d)
fi

# collect all workflow paths for this version
WORKFLOW_IDENTITIES=()

for FILE in $RW_FILES; do
  # cert-id with commit sha
  IDENTITY="https://github.com/liatrio/liatrio-gh-autogov-workflows/$FILE@$COMMIT_SHA"
  WORKFLOW_IDENTITIES+=("$IDENTITY")
  DISPLAY_NAME=$(basename "$FILE" | sed 's/\.ya\?ml$//' | tr '[:lower:]' '[:upper:]' | sed 's/RW-//')
  echo "Including $DISPLAY_NAME v$VERSION in flattened identity format"
done

# create a flattened version using jq
if [ -f "cert-identities.json" ]; then
  # check if already flattened format or need to convert
  if jq -e '.identities' cert-identities.json >/dev/null 2>&1; then
    echo "Existing flattened format detected, updating..."
    # already flattened format
    cp cert-identities.json cert-identities.tmp.json
  else
    echo "Converting to flattened format..."
    # convert from legacy to flattened format
    # start with empty identities array
    echo '{"identities": []}' >cert-identities.tmp.json

    # convert latest entries
    for ENTRY in $(jq -c '.latest[]?' cert-identities.json 2>/dev/null || echo '[]'); do
      if [ "$ENTRY" != "[]" ] && [ -n "$ENTRY" ]; then
        VERSION=$(echo "$ENTRY" | jq -r '.version')
        IDENTITY_URL=$(echo "$ENTRY" | jq -r '.identity')
        ADDED=$(echo "$ENTRY" | jq -r '.added')
        EXPIRES=$(echo "$ENTRY" | jq -r '.expires // ""')
        SHA=$(echo "$IDENTITY_URL" | cut -d '@' -f 2)

        # add as 'latest' status entry
        jq --arg version "$VERSION" \
          --arg sha "$SHA" \
          --arg added "$ADDED" \
          --arg expires "$EXPIRES" \
          --arg identity "$IDENTITY_URL" \
          '.identities += [{
             "version": $version,
             "sha": $sha,
             "status": "latest",
             "identities": [$identity],
             "added": $added,
             "expires": $expires
           }]' cert-identities.tmp.json >cert-identities.tmp2.json
        mv cert-identities.tmp2.json cert-identities.tmp.json
      fi
    done

    # convert approved entries
    for ENTRY in $(jq -c '.approved[]?' cert-identities.json 2>/dev/null || echo '[]'); do
      if [ "$ENTRY" != "[]" ] && [ -n "$ENTRY" ]; then
        VERSION=$(echo "$ENTRY" | jq -r '.version')
        IDENTITY_URL=$(echo "$ENTRY" | jq -r '.identity')
        ADDED=$(echo "$ENTRY" | jq -r '.added')
        EXPIRES=$(echo "$ENTRY" | jq -r '.expires // ""')
        SHA=$(echo "$IDENTITY_URL" | cut -d '@' -f 2)

        # add as 'approved' status entry
        jq --arg version "$VERSION" \
          --arg sha "$SHA" \
          --arg added "$ADDED" \
          --arg expires "$EXPIRES" \
          --arg identity "$IDENTITY_URL" \
          '.identities += [{
             "version": $version,
             "sha": $sha,
             "status": "approved",
             "identities": [$identity],
             "added": $added,
             "expires": $expires
           }]' cert-identities.tmp.json >cert-identities.tmp2.json
        mv cert-identities.tmp2.json cert-identities.tmp.json
      fi
    done

    # convert revoked entries
    for ENTRY in $(jq -c '.revoked[]?' cert-identities.json 2>/dev/null || echo '[]'); do
      if [ "$ENTRY" != "[]" ] && [ -n "$ENTRY" ]; then
        VERSION=$(echo "$ENTRY" | jq -r '.version')
        IDENTITY_URL=$(echo "$ENTRY" | jq -r '.identity')
        ADDED=$(echo "$ENTRY" | jq -r '.added')
        REVOKED=$(echo "$ENTRY" | jq -r '.revoked // ""')
        REASON=$(echo "$ENTRY" | jq -r '.reason // ""')
        SHA=$(echo "$IDENTITY_URL" | cut -d '@' -f 2)

        # add as 'revoked' status entry
        jq --arg version "$VERSION" \
          --arg sha "$SHA" \
          --arg added "$ADDED" \
          --arg revoked "$REVOKED" \
          --arg reason "$REASON" \
          --arg identity "$IDENTITY_URL" \
          '.identities += [{
             "version": $version,
             "sha": $sha,
             "status": "revoked",
             "identities": [$identity],
             "added": $added,
             "revoked": $revoked,
             "reason": $reason
           }]' cert-identities.tmp.json >cert-identities.tmp2.json
        mv cert-identities.tmp2.json cert-identities.tmp.json
      fi
    done
  fi
else
  # create new empty identities list
  echo '{"identities": []}' >cert-identities.tmp.json
fi

# convert workflow identities array to json
IDENTITIES_JSON="["
for i in "${!WORKFLOW_IDENTITIES[@]}"; do
  IDENTITIES_JSON+="\"${WORKFLOW_IDENTITIES[$i]}\""
  if [ $i -lt $((${#WORKFLOW_IDENTITIES[@]} - 1)) ]; then
    IDENTITIES_JSON+=","
  fi
done
IDENTITIES_JSON+="]"

# update all existing "latest" entries to be "approved"
echo "Updating any existing 'latest' entries to 'approved'..."
jq '.identities = (.identities | map(if .status == "latest" then . + {"status": "approved"} else . end))' cert-identities.tmp.json > cert-identities.tmp2.json
mv cert-identities.tmp2.json cert-identities.tmp.json

# check if version exists in identities (regardless of status)
VERSION_EXISTS=$(jq --arg version "$VERSION" -r '.identities[] | select(.version == $version) | .version' cert-identities.tmp.json)

if [ -z "$VERSION_EXISTS" ]; then
  echo "Adding new version $VERSION to identities"
  # add new entry for this version
  jq --arg version "$VERSION" \
    --arg sha "$COMMIT_SHA" \
    --arg added "$TODAY" \
    --arg expires "$EXPIRY_DATE" \
    --argjson identities "$IDENTITIES_JSON" \
    '.identities = [{
       "version": $version,
       "sha": $sha,
       "status": "latest",
       "identities": $identities,
       "added": $added,
       "expires": $expires
     }] + .identities' cert-identities.tmp.json >cert-identities.tmp2.json
  mv cert-identities.tmp2.json cert-identities.tmp.json
else
  echo "Version $VERSION already exists, updating to latest status..."
  # update existing entry
  jq --arg version "$VERSION" \
    --arg sha "$COMMIT_SHA" \
    --arg added "$TODAY" \
    --arg expires "$EXPIRY_DATE" \
    --argjson identities "$IDENTITIES_JSON" \
    '.identities = (.identities | map(if .version == $version and .status == "latest" then {
       "version": $version,
       "sha": $sha,
       "status": "latest",
       "identities": $identities,
       "added": $added,
       "expires": $expires
     } else . end))' cert-identities.tmp.json >cert-identities.tmp2.json
  mv cert-identities.tmp2.json cert-identities.tmp.json
fi

# check for expired entries and move to revoked
echo "Checking for expired certificate identities..."

# get today's date in seconds since epoch for comparison
if date -d "$TODAY" +%s &>/dev/null; then
  # Linux format
  TODAY_SECONDS=$(date -d "$TODAY" +%s)
else
  # macos format
  TODAY_SECONDS=$(date -j -f "%Y-%m-%d" "$TODAY" +%s)
fi

jq \
  --arg today "$TODAY" \
  --argjson today_seconds "$TODAY_SECONDS" \
  '# define date handling helper functions
   def date_to_seconds(date_str): 
     if date_str == null or date_str == "" then null 
     else (date_str | strptime("%Y-%m-%d") | mktime) 
     end;

   # check expired
   def is_expired(entry):
     entry.expires != null and entry.expires != "" and
     (date_to_seconds(entry.expires) < $today_seconds);
     
   # move expired approved entries to revoked
   .identities = (.identities | map(
     if .status == "approved" and is_expired(.) then
       . + {"status": "revoked", "revoked": $today, "reason": "Certificate expired"}
     else
       .
     end
   ))' \
  cert-identities.tmp.json >cert-identities.tmp2.json

mv cert-identities.tmp2.json cert-identities.tmp.json

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

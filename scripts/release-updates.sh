#!/bin/bash
set -e

# This script runs all release-related updates
VERSION="${VERSION:-$1}"

if [ -z "$VERSION" ]; then
  echo "Error: No version provided"
  echo "Usage: $0 <version> or set VERSION env var"
  exit 1
fi

echo "Running release updates for version $VERSION"

# Run update scripts
./scripts/update-dockerfile.sh "$VERSION"
./scripts/update-cert-identities.sh "$VERSION"

echo "All release updates completed successfully"

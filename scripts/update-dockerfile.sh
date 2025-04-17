#!/bin/bash
set -e

# updates Dockerfile's VERSION variable

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "Error: No version provided"
  echo "Usage: $0 <version>"
  exit 1
fi

echo "Updating Dockerfile version to $VERSION"
sed -i "s/ENV VERSION=\".*\"/ENV VERSION=\"$VERSION\"/" Dockerfile
echo "Successfully updated Dockerfile version"

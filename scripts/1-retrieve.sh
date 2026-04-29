#!/bin/bash

# -----------------------------------------------
# Data Cloud Retrieve Script
# Retrieves metadata from a source org using all manifests in manifests/,
# then commits and pushes to GitHub.
#
# Usage: ./scripts/1-retrieve.sh <source-org> <commit-message>
# Example: ./scripts/1-retrieve.sh mysdo-dev "Add room reservation DMO"
# -----------------------------------------------

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "ERROR: Missing required arguments."
  echo "Usage: ./scripts/1-retrieve.sh <source-org> <commit-message>"
  exit 1
fi

SOURCE_ORG=$1
COMMIT_MESSAGE=$2

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="$PROJECT_ROOT/manifests"
METADATA_DIR="$PROJECT_ROOT/force-app/main/default"

# Check manifests folder exists and has at least one xml
MANIFEST_FILES=("$MANIFESTS_DIR"/*.xml)
if [ ! -e "${MANIFEST_FILES[0]}" ]; then
  echo "ERROR: No manifest files found in $MANIFESTS_DIR"
  echo "→ Place one or more package.xml files in the manifests/ folder"
  exit 1
fi

echo "Found ${#MANIFEST_FILES[@]} manifest(s) in manifests/"

# Clear data kit folders before retrieving so stale entries inherited from
# the parent branch don't persist alongside the new feature.
echo ""
echo "Clearing dataPackageKitDefinitions and DataPackageKitObjects..."
rm -rf "$METADATA_DIR/dataPackageKitDefinitions"
mkdir -p "$METADATA_DIR/dataPackageKitDefinitions"
rm -rf "$METADATA_DIR/DataPackageKitObjects"
mkdir -p "$METADATA_DIR/DataPackageKitObjects"
echo "✓ Cleared."

# Retrieve from source org for each manifest
for MANIFEST in "${MANIFEST_FILES[@]}"; do
  echo ""
  echo "Retrieving using $(basename $MANIFEST) from $SOURCE_ORG..."

  # Strip ExtDataTranFieldTemplate before retrieve (unsupported by Metadata API)
  MANIFEST_BACKUP=$(mktemp -t package-xml-backup)
  cp "$MANIFEST" "$MANIFEST_BACKUP"

  python3 -c "
import re
file = '$MANIFEST'
content = open(file).read()
content = re.sub(
    r'\n?\s*<types>(?:(?!</types>)[\s\S])*?<name>[Ee]xtDataTranFieldTemplate</name>(?:(?!</types>)[\s\S])*?</types>',
    '', content)
open(file, 'w').write(content)
"
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to strip unsupported types from $(basename $MANIFEST)"
    cp "$MANIFEST_BACKUP" "$MANIFEST"
    rm -f "$MANIFEST_BACKUP"
    exit 1
  fi

  sf project retrieve start \
    --manifest "$MANIFEST" \
    --target-org "$SOURCE_ORG" \
    --wait 30 < /dev/null

  RETRIEVE_STATUS=$?

  # Restore manifest immediately after retrieve
  cp "$MANIFEST_BACKUP" "$MANIFEST"
  rm -f "$MANIFEST_BACKUP"

  if [ $RETRIEVE_STATUS -ne 0 ]; then
    echo ""
    echo "ERROR: Retrieve failed using $(basename $MANIFEST)"
    echo "→ Check that $SOURCE_ORG is authenticated: sf org list"
    echo "→ Check that the manifest is valid and the Data Kit is published in $SOURCE_ORG"
    exit 1
  fi

  echo "✓ Retrieve successful for $(basename $MANIFEST)"
done

# Commit and push all retrieved metadata
echo ""
echo "Committing and pushing to GitHub..."
git add -A

if git diff --cached --quiet; then
  echo "  No metadata changes to commit — skipping commit, pushing any prior commits."
else
  git commit -m "$COMMIT_MESSAGE"
  if [ $? -ne 0 ]; then
    echo "ERROR: Git commit failed."
    exit 1
  fi
fi

git push
if [ $? -ne 0 ]; then
  echo "ERROR: Git push failed."
  echo "→ Check your GitHub remote is configured: git remote -v"
  echo "→ Check that you have write access to the repo"
  exit 1
fi

echo "✓ Pushed to GitHub."
echo ""
echo "Next step: open a Pull Request on GitHub to merge this branch into the target branch."

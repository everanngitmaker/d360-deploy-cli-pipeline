#!/bin/bash

# -----------------------------------------------
# Data Cloud Deploy Script
# Pulls latest from GitHub, preprocesses metadata, and deploys to target org.
#
# Usage: ./scripts/3-deploy.sh <target-org> [--dry-run]
# Example: ./scripts/3-deploy.sh mysdo-stage
# Dry run: ./scripts/3-deploy.sh mysdo-stage --dry-run
# -----------------------------------------------

if [ -z "$1" ]; then
  echo "ERROR: Missing required argument."
  echo "Usage: ./scripts/3-deploy.sh <target-org> [--dry-run]"
  exit 1
fi

TARGET_ORG=$1
DRY_RUN=$2
PROD_ORG="mysdo"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="$PROJECT_ROOT/manifests"
METADATA_DIR="$PROJECT_ROOT/force-app/main/default"

# Check manifests folder exists and has at least one xml
MANIFEST_FILES=("$MANIFESTS_DIR"/*.xml)
if [ ! -e "${MANIFEST_FILES[0]}" ]; then
  echo "ERROR: No manifest files found in $MANIFESTS_DIR"
  exit 1
fi

# Check if dry run
if [ "$DRY_RUN" == "--dry-run" ]; then
  echo "⚠️  DRY RUN MODE — no changes will be deployed."
fi

# Safety check if deploying to prod
if [ "$TARGET_ORG" == "$PROD_ORG" ] && [ "$DRY_RUN" != "--dry-run" ]; then
  echo ""
  echo "⚠️  WARNING: You are about to deploy to PRODUCTION ($TARGET_ORG)."
  echo "   Have you run a dry run first? (./scripts/3-deploy.sh $TARGET_ORG --dry-run)"
  echo ""
  echo "   Type 'yes' to confirm and proceed with production deployment:"
  read CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
  fi
fi

# Pull latest from GitHub before deploying
echo ""
echo "Pulling latest from GitHub..."
git pull
if [ $? -ne 0 ]; then
  echo "ERROR: Git pull failed."
  echo "→ Resolve any conflicts before deploying"
  exit 1
fi
echo "✓ Up to date with GitHub."

# Back up all manifests before preprocessing
BACKUP_DIR=$(mktemp -d -t manifest-backups)
for MANIFEST in "${MANIFEST_FILES[@]}"; do
  BACKUP_NAME=$(basename "$MANIFEST")
  cp "$MANIFEST" "$BACKUP_DIR/$BACKUP_NAME"
done

restore_manifests() {
  for MANIFEST in "${MANIFEST_FILES[@]}"; do
    BACKUP_NAME=$(basename "$MANIFEST")
    cp "$BACKUP_DIR/$BACKUP_NAME" "$MANIFEST"
  done
  rm -rf "$BACKUP_DIR"
}

# Preprocess all manifests: strip ExtDataTranFieldTemplate
echo ""
echo "Preprocessing manifests..."
for MANIFEST in "${MANIFEST_FILES[@]}"; do
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
    restore_manifests
    exit 1
  fi
done
echo "✓ Unsupported metadata types removed."

# Orphan check — run once across all manifests
echo ""
echo "Checking for orphaned package.xml members..."
for MANIFEST in "${MANIFEST_FILES[@]}"; do
python3 - <<PYEOF
import os, re, xml.etree.ElementTree as ET

manifest    = '$MANIFEST'
meta_dir    = '$METADATA_DIR'
ns          = 'http://soap.sforce.com/2006/04/metadata'
SKIP_TYPES  = {'CustomField', 'CustomObject'}

present = set()
for root, dirs, files in os.walk(meta_dir):
    for f in files:
        if f.endswith('-meta.xml'):
            stem = os.path.splitext(f[:-len('-meta.xml')])[0]
        else:
            stem = os.path.splitext(f)[0]
        present.add(stem)

content = open(manifest).read()
tree    = ET.fromstring(content)
orphans = []

for types_el in tree.findall(f'{{{ns}}}types'):
    name_el = types_el.find(f'{{{ns}}}name')
    if name_el is None or name_el.text in SKIP_TYPES:
        continue
    for m in types_el.findall(f'{{{ns}}}members'):
        if m.text and m.text.strip() not in present:
            orphans.append(m.text.strip())

if not orphans:
    print('  All members present.')
else:
    for name in orphans:
        print(f'  Removing orphaned member: {name}')
        content = re.sub(rf'\s*<members>{re.escape(name)}</members>', '', content)
    open(manifest, 'w').write(content)
    print(f'  Removed {len(orphans)} orphaned member(s) from $(basename $MANIFEST).')
PYEOF
  if [ $? -ne 0 ]; then
    echo "ERROR: Orphan check failed for $(basename $MANIFEST)"
    restore_manifests
    exit 1
  fi
done
echo "✓ Orphan check complete."

# Remove KQ_ fields
echo ""
echo "Removing KQ_ fields..."
python3 - <<PYEOF
import os, glob, re

manifests_dir = '$MANIFESTS_DIR'
objects_dir   = '$METADATA_DIR/objects'

removed = []
for fpath in glob.glob(os.path.join(objects_dir, '*', 'fields', 'KQ_*.field-meta.xml')):
    obj_name   = os.path.basename(os.path.dirname(os.path.dirname(fpath)))
    field_name = os.path.basename(fpath).replace('.field-meta.xml', '')
    os.remove(fpath)
    removed.append(f'{obj_name}.{field_name}')
    print(f'  Deleted {obj_name}/fields/{field_name}.field-meta.xml')

if removed:
    for manifest_file in glob.glob(os.path.join(manifests_dir, '*.xml')):
        content = open(manifest_file).read()
        for member in removed:
            content = re.sub(rf'\s*<members>{re.escape(member)}</members>', '', content)
        open(manifest_file, 'w').write(content)
    print(f'  Removed {len(removed)} KQ_ field(s) across all manifests.')
else:
    print('  No KQ_ field files found.')
PYEOF
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to remove KQ_ fields."
  restore_manifests
  exit 1
fi
echo "✓ KQ_ fields removed."

# Sync CustomField members for each manifest
echo ""
echo "Syncing CustomField members..."
for MANIFEST in "${MANIFEST_FILES[@]}"; do
python3 - <<PYEOF
import re, os, glob

manifest    = '$MANIFEST'
objects_dir = '$METADATA_DIR/objects'

custom_fields = []
for fpath in sorted(glob.glob(os.path.join(objects_dir, '*', 'fields', '*.field-meta.xml'))):
    obj_name   = os.path.basename(os.path.dirname(os.path.dirname(fpath)))
    field_name = os.path.basename(fpath).replace('.field-meta.xml', '')
    custom_fields.append(f'{obj_name}.{field_name}')

if not custom_fields:
    print('  No field files found — skipping sync.')
    exit(0)

members_xml = '\n'.join(f'        <members>{f}</members>' for f in sorted(custom_fields))
new_types_block = f"""    <types>
{members_xml}
        <name>CustomField</name>
    </types>"""

content = open(manifest).read()
content = re.sub(
    r'\n?\s*<types>(?:(?!</types>)[\s\S])*?<name>CustomField</name>(?:(?!</types>)[\s\S])*?</types>',
    '', content)

if '    <version>' in content:
    content = content.replace('    <version>', f'{new_types_block}\n    <version>', 1)
else:
    content = content.replace('</Package>', f'\n{new_types_block}\n</Package>')

open(manifest, 'w').write(content)
print(f'  Synced {len(custom_fields)} CustomField members in $(basename $MANIFEST).')
PYEOF
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to sync CustomField members in $(basename $MANIFEST)"
    restore_manifests
    exit 1
  fi
done
echo "✓ CustomField members synced."

# DataPackageKitObject orphan check
echo ""
echo "Checking for orphaned DataPackageKitObject entries..."
for MANIFEST in "${MANIFEST_FILES[@]}"; do
python3 - <<PYEOF
import re, os, xml.etree.ElementTree as ET

manifest = '$MANIFEST'
dpko_dir = '$METADATA_DIR/DataPackageKitObjects'
ns       = 'http://soap.sforce.com/2006/04/metadata'

content  = open(manifest).read()
pkg_tree = ET.fromstring(content)
orphaned = []

for types_el in pkg_tree.findall(f'{{{ns}}}types'):
    name_el = types_el.find(f'{{{ns}}}name')
    if name_el is not None and name_el.text == 'DataPackageKitObject':
        for m in types_el.findall(f'{{{ns}}}members'):
            if m.text:
                dpko_name = m.text.strip()
                dpko_file = os.path.join(dpko_dir, f'{dpko_name}.DataPackageKitObject-meta.xml')
                if not os.path.exists(dpko_file):
                    orphaned.append(dpko_name)
                    print(f'  Removing orphaned DataPackageKitObject: {dpko_name}')

if orphaned:
    for dpko in orphaned:
        content = re.sub(rf'\s*<members>{re.escape(dpko)}</members>', '', content)
    open(manifest, 'w').write(content)
    print(f'  Removed {len(orphaned)} orphaned entry(s) from $(basename $MANIFEST).')
else:
    print('  All DataPackageKitObject entries present.')
PYEOF
  if [ $? -ne 0 ]; then
    echo "ERROR: DataPackageKitObject check failed for $(basename $MANIFEST)"
    restore_manifests
    exit 1
  fi
done
echo "✓ DataPackageKitObject check complete."

# Deploy using first manifest (all metadata is already on disk from retrieve)
# We use the first manifest as the deploy manifest; metadata files cover all kits.
DEPLOY_MANIFEST="${MANIFEST_FILES[0]}"
echo ""
if [ "$DRY_RUN" == "--dry-run" ]; then
  echo "Validating deployment to $TARGET_ORG (dry run)..."
  sf project deploy start \
    --manifest "$DEPLOY_MANIFEST" \
    --target-org "$TARGET_ORG" \
    --dry-run \
    --wait 30 < /dev/null
else
  echo "Deploying Data Cloud metadata to $TARGET_ORG..."
  sf project deploy start \
    --manifest "$DEPLOY_MANIFEST" \
    --target-org "$TARGET_ORG" \
    --wait 30 < /dev/null
fi

DEPLOY_STATUS=$?

# Restore all manifests
echo ""
echo "Restoring manifests to original state..."
restore_manifests
echo "✓ Manifests restored."

if [ $DEPLOY_STATUS -ne 0 ]; then
  echo ""
  echo "ERROR: Deploy to $TARGET_ORG failed."
  echo "→ Check that $TARGET_ORG is authenticated: sf org list"
  echo "→ Review deployment errors above for specific component failures"
  exit 1
fi

echo ""
if [ "$DRY_RUN" == "--dry-run" ]; then
  echo "✓ Dry run complete — no changes deployed."
else
  echo "✓ Metadata deployed to $TARGET_ORG."
  echo ""
  echo "⚠️  Manual step required: go to Data Cloud Setup → Data Kits → Deploy"
  echo "   This activates data streams and other runtime components in $TARGET_ORG."
fi

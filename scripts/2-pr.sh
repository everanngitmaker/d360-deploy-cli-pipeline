#!/bin/bash

# -----------------------------------------------
# Data Cloud PR Script
# Creates a pull request from source branch to target branch,
# with option to auto-merge.
#
# Usage: ./scripts/2-pr.sh <source-branch> <target-branch>
# Example: ./scripts/2-pr.sh feature/add-profile-search stage
# -----------------------------------------------

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "ERROR: Missing required arguments."
  echo "Usage: ./scripts/2-pr.sh <source-branch> <target-branch>"
  exit 1
fi

SOURCE_BRANCH=$1
TARGET_BRANCH=$2

# Check gh CLI is available
if ! command -v gh &> /dev/null; then
  echo "ERROR: gh CLI not found. Install it from https://cli.github.com"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_CONFIG="$PROJECT_ROOT/config/pipeline.config"

# Enforce promotion order for feature branches if pipeline.config exists
if [[ "$SOURCE_BRANCH" == feature/* ]] && [ -f "$PIPELINE_CONFIG" ]; then
  PROMOTION_ORDER=$(grep '^PROMOTION_ORDER=' "$PIPELINE_CONFIG" | cut -d'=' -f2 | tr ',' ' ')
  PREV_BRANCH=""
  for BRANCH in $PROMOTION_ORDER; do
    if [ "$BRANCH" == "$TARGET_BRANCH" ] && [ -n "$PREV_BRANCH" ]; then
      echo ""
      echo "Checking that $SOURCE_BRANCH has already been merged into $PREV_BRANCH..."
      MERGED=$(gh pr list --base "$PREV_BRANCH" --state merged --head "$SOURCE_BRANCH" --json number --jq 'length')
      if [ "$MERGED" -eq 0 ]; then
        echo ""
        echo "ERROR: $SOURCE_BRANCH has not been merged into $PREV_BRANCH yet."
        echo "→ Run: ./scripts/2-pr.sh $SOURCE_BRANCH $PREV_BRANCH"
        echo "→ Validate in $PREV_BRANCH, then promote to $TARGET_BRANCH."
        exit 1
      fi
      echo "✓ Already merged into $PREV_BRANCH."
      break
    fi
    PREV_BRANCH="$BRANCH"
  done
fi

echo ""
echo "Creating PR: $SOURCE_BRANCH → $TARGET_BRANCH..."

PR_URL=$(gh pr create \
  --base "$TARGET_BRANCH" \
  --head "$SOURCE_BRANCH" \
  --title "$SOURCE_BRANCH → $TARGET_BRANCH" \
  --body "" \
  2>&1)

if [ $? -ne 0 ]; then
  # If PR already exists, extract its URL
  EXISTING=$(gh pr view "$SOURCE_BRANCH" --base "$TARGET_BRANCH" --json url --jq '.url' 2>/dev/null)
  if [ -n "$EXISTING" ]; then
    echo "  PR already exists: $EXISTING"
    PR_URL="$EXISTING"
  else
    echo "ERROR: Failed to create PR."
    echo "$PR_URL"
    exit 1
  fi
else
  echo "✓ PR created: $PR_URL"
fi

echo ""
echo "What would you like to do?"
echo "  1) Review PR on GitHub (open in browser)"
echo "  2) Merge PR now"
echo "  3) Skip — I'll handle it manually"
echo ""
read -p "Enter choice [1/2/3]: " CHOICE

case "$CHOICE" in
  1)
    gh pr view --web "$SOURCE_BRANCH" 2>/dev/null || open "$PR_URL"
    echo "✓ Opened PR in browser."
    ;;
  2)
    echo ""
    echo "Merging PR..."
    gh pr merge "$SOURCE_BRANCH" \
      --base "$TARGET_BRANCH" \
      --merge \
      --delete-branch=false
    if [ $? -ne 0 ]; then
      echo "ERROR: Merge failed. Check for conflicts on GitHub."
      exit 1
    fi
    echo "✓ PR merged: $SOURCE_BRANCH → $TARGET_BRANCH"

    # After merging to the last branch in the promotion order, offer to delete the feature branch
    LAST_BRANCH=$(grep '^PROMOTION_ORDER=' "$PIPELINE_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr ',' '\n' | tail -1)
    if [[ "$SOURCE_BRANCH" == feature/* ]] && [ "$TARGET_BRANCH" == "$LAST_BRANCH" ]; then
      echo ""
      read -p "Delete feature branch $SOURCE_BRANCH? [y/n]: " DELETE_CHOICE
      if [ "$DELETE_CHOICE" == "y" ]; then
        git branch -d "$SOURCE_BRANCH" 2>/dev/null || git branch -D "$SOURCE_BRANCH"
        git push origin --delete "$SOURCE_BRANCH"
        echo "✓ Deleted $SOURCE_BRANCH locally and remotely."
      else
        echo "  Skipping branch deletion."
      fi
    fi

    echo ""
    echo "Next step: run ./scripts/3-deploy.sh <target-org>"
    ;;
  3)
    echo "  Skipping — PR is ready at: $PR_URL"
    ;;
  *)
    echo "  Invalid choice — PR is ready at: $PR_URL"
    ;;
esac

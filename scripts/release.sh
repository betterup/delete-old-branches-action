#!/usr/bin/env bash
# scripts/release.sh - Interactive GitHub release creator
# Usage: ./scripts/release.sh

set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────────────────

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

die() { red "Error: $*" >&2; exit 1; }

semver_valid() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

semver_parts() {
  local tag="${1#v}"   # strip leading 'v'
  IFS='.' read -r major minor patch <<< "$tag"
  echo "$major" "$minor" "$patch"
}

bump_version() {
  local base="$1" bump="$2"
  read -r major minor patch <<< "$(semver_parts "$base")"
  case "$bump" in
    major) echo "v$((major + 1)).0.0" ;;
    minor) echo "v${major}.$((minor + 1)).0" ;;
    patch) echo "v${major}.${minor}.$((patch + 1))" ;;
  esac
}

# ─── Prereqs ──────────────────────────────────────────────────────────────────

command -v gh  >/dev/null 2>&1 || die "'gh' CLI not found. Install from https://cli.github.com"
command -v git >/dev/null 2>&1 || die "'git' not found."

gh auth status >/dev/null 2>&1 || die "Not authenticated. Run: gh auth login"

# ─── Repo context ─────────────────────────────────────────────────────────────

REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) \
  || die "Not inside a GitHub repository (or 'gh repo view' failed)."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
CURRENT_SHA=$(git rev-parse HEAD)

echo
bold "=== GitHub Release Creator ==="
info "Repo:   $REPO"
info "Branch: $CURRENT_BRANCH"
info "SHA:    $CURRENT_SHA"
echo

# ─── Fetch latest remote tags ─────────────────────────────────────────────────

printf 'Fetching tags from remote...'
git fetch --tags --quiet
printf ' done.\n\n'

# ─── List existing tags ───────────────────────────────────────────────────────

EXISTING_TAGS=$(git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
LATEST_TAG=$(echo "$EXISTING_TAGS" | head -1)

if [[ -z "$EXISTING_TAGS" ]]; then
  bold "No existing semver tags found."
  LATEST_TAG=""
else
  bold "Existing tags (most recent first):"
  echo "$EXISTING_TAGS" | head -15 | while read -r t; do
    info "$t"
  done
  total=$(echo "$EXISTING_TAGS" | wc -l | tr -d ' ')
  [[ $total -gt 15 ]] && info "... and $((total - 15)) more"
  echo
  info "Latest tag: $LATEST_TAG"
  echo
fi

# ─── Choose / create a tag ────────────────────────────────────────────────────

bold "How would you like to set the new tag?"
echo "  1) Bump patch  $([ -n "$LATEST_TAG" ] && bump_version "$LATEST_TAG" patch || echo '(no base tag)')"
echo "  2) Bump minor  $([ -n "$LATEST_TAG" ] && bump_version "$LATEST_TAG" minor || echo '(no base tag)')"
echo "  3) Bump major  $([ -n "$LATEST_TAG" ] && bump_version "$LATEST_TAG" major || echo '(no base tag)')"
echo "  4) Enter a custom tag"
echo

while true; do
  read -rp "Choice [1-4]: " choice
  case "$choice" in
    1|2|3)
      if [[ -z "$LATEST_TAG" ]]; then
        red "No existing tag to bump from. Choose option 4 to enter a custom tag."
        continue
      fi
      case "$choice" in
        1) NEW_TAG=$(bump_version "$LATEST_TAG" patch) ;;
        2) NEW_TAG=$(bump_version "$LATEST_TAG" minor) ;;
        3) NEW_TAG=$(bump_version "$LATEST_TAG" major) ;;
      esac
      break
      ;;
    4)
      while true; do
        read -rp "Enter new tag (e.g. v1.2.3): " NEW_TAG
        if semver_valid "$NEW_TAG"; then
          break
        else
          red "Invalid format. Tag must match vX.X.X (e.g. v1.2.3)."
        fi
      done
      break
      ;;
    *)
      red "Please enter 1, 2, 3, or 4."
      ;;
  esac
done

echo
bold "New tag: $NEW_TAG"

# Check for tag collision
if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
  yellow "Tag '$NEW_TAG' already exists locally."
  EXISTING_TAG_SHA=$(git rev-parse "$NEW_TAG^{}")
  info "Points to: $EXISTING_TAG_SHA"
  read -rp "Use this existing tag? [y/N]: " use_existing
  if [[ ! "$use_existing" =~ ^[Yy]$ ]]; then
    die "Aborted. Please choose a different tag."
  fi
  TAG_ALREADY_EXISTS=true
else
  TAG_ALREADY_EXISTS=false
fi

echo

# ─── Create local tag if needed ───────────────────────────────────────────────

if [[ "$TAG_ALREADY_EXISTS" == false ]]; then
  read -rp "Tag message (leave blank for default \"Release $NEW_TAG\"): " tag_message
  tag_message="${tag_message:-Release $NEW_TAG}"

  git tag -a "$NEW_TAG" -m "$tag_message"
  green "Created local tag '$NEW_TAG'."
  echo
fi

# ─── Push tag to remote ───────────────────────────────────────────────────────

read -rp "Push tag '$NEW_TAG' to origin? [Y/n]: " push_confirm
if [[ "$push_confirm" =~ ^[Nn]$ ]]; then
  die "Aborted before pushing tag."
fi

git push origin "$NEW_TAG"
green "Pushed tag '$NEW_TAG' to origin."
echo

# ─── Build release notes ──────────────────────────────────────────────────────

bold "Generating release notes..."

# Determine the commit range for the changelog
if [[ -n "$LATEST_TAG" && "$NEW_TAG" != "$LATEST_TAG" ]]; then
  RANGE="${LATEST_TAG}..HEAD"
  bold "Commits since $LATEST_TAG:"
  git log "$RANGE" --oneline | while read -r line; do info "$line"; done
else
  bold "No previous tag to diff against — showing last 10 commits:"
  git log --oneline -10 | while read -r line; do info "$line"; done
fi

echo

# Let gh generate notes automatically, then let the user edit
NOTES_FILE=$(mktemp /tmp/release-notes.XXXXXX.md)
trap 'rm -f "$NOTES_FILE"' EXIT

# Use gh's auto-generated notes as the starting point
gh api \
  --method POST \
  "/repos/${REPO}/releases/generate-notes" \
  -f "tag_name=${NEW_TAG}" \
  ${LATEST_TAG:+-f "previous_tag_name=${LATEST_TAG}"} \
  --jq '.body' > "$NOTES_FILE" 2>/dev/null \
  || printf "## What's Changed\n\n<!-- Add release notes here -->\n" > "$NOTES_FILE"

green "Auto-generated release notes written to temp file."
echo

read -rp "Open notes in \$EDITOR to review/edit before creating release? [Y/n]: " edit_notes
if [[ ! "$edit_notes" =~ ^[Nn]$ ]]; then
  EDITOR="${EDITOR:-vi}"
  "$EDITOR" "$NOTES_FILE"
fi

RELEASE_NOTES=$(cat "$NOTES_FILE")

# ─── Release options ──────────────────────────────────────────────────────────

echo
bold "Release options:"

read -rp "Mark as pre-release? [y/N]: " is_prerelease
read -rp "Create as draft (do not publish yet)? [y/N]: " is_draft
read -rp "Mark as latest release? [Y/n]: " is_latest

PRERELEASE_FLAG=""
[[ "$is_prerelease" =~ ^[Yy]$ ]] && PRERELEASE_FLAG="--prerelease"

DRAFT_FLAG=""
[[ "$is_draft" =~ ^[Yy]$ ]] && DRAFT_FLAG="--draft"

LATEST_FLAG="--latest"
[[ "$is_latest" =~ ^[Nn]$ ]] && LATEST_FLAG=""

# ─── Confirm & create release ─────────────────────────────────────────────────

echo
bold "=== Summary ==="
info "Repo:       $REPO"
info "Tag:        $NEW_TAG"
info "Draft:      $( [[ -n "$DRAFT_FLAG" ]] && echo yes || echo no )"
info "Pre-release:$( [[ -n "$PRERELEASE_FLAG" ]] && echo yes || echo no )"
info "Latest:     $( [[ -n "$LATEST_FLAG" ]] && echo yes || echo no )"
echo
bold "Release notes:"
echo "$RELEASE_NOTES"
echo

read -rp "Create release now? [Y/n]: " final_confirm
if [[ "$final_confirm" =~ ^[Nn]$ ]]; then
  # Clean up the remote tag we just pushed if the user bails
  read -rp "Delete the remote tag '$NEW_TAG' since we're aborting? [y/N]: " del_remote
  if [[ "$del_remote" =~ ^[Yy]$ ]]; then
    git push origin ":refs/tags/$NEW_TAG"
    [[ "$TAG_ALREADY_EXISTS" == false ]] && git tag -d "$NEW_TAG"
    green "Remote (and local) tag removed."
  fi
  die "Release creation cancelled."
fi

# ─── Create the release ───────────────────────────────────────────────────────

RELEASE_URL=$(gh release create "$NEW_TAG" \
  --title "$NEW_TAG" \
  --notes "$RELEASE_NOTES" \
  $DRAFT_FLAG \
  $PRERELEASE_FLAG \
  $LATEST_FLAG \
  2>&1)

echo
green "Release created successfully!"
info "URL: $RELEASE_URL"
echo

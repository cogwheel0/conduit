#!/bin/bash

# Conduit Mobile Release Script (CI-driven)
# Usage:
#   ./scripts/release.sh [major|minor|patch]
#   ./scripts/release.sh rebuild [vX.Y.Z]   # Rebuild existing tag, bump build number only, update same release assets

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [ ! -f "pubspec.yaml" ]; then
    print_error "This script must be run from the project root directory"
    exit 1
fi

ACTION=${1:-patch}

if [ "$ACTION" = "rebuild" ]; then
  # Rebuild path: Update existing release assets without changing the tag/version name
  # Optionally accepts a tag argument; defaults to latest tag.
  TAG_ARG=$2
  if [ -z "$TAG_ARG" ]; then
    TAG_VERSION=$(git describe --tags --abbrev=0)
  else
    TAG_VERSION=$TAG_ARG
  fi

  if [ -z "$TAG_VERSION" ]; then
    print_error "No tag found. Provide an explicit tag: ./scripts/release.sh rebuild vX.Y.Z"
    exit 1
  fi

  print_status "Rebuilding existing release for tag: $TAG_VERSION"
  echo
  read -p "Proceed to rebuild $TAG_VERSION and update its assets? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_warning "Rebuild cancelled"
      exit 0
  fi

  if command -v gh >/dev/null 2>&1; then
    print_status "Dispatching GitHub Actions workflow (Release) via gh CLI..."
    gh workflow run "Release" \
      --ref main \
      -f tag="$TAG_VERSION" \
      -f remove_old_assets=true
    print_status "Workflow dispatched. Track progress in GitHub Actions."
  else
    print_warning "GitHub CLI (gh) not found. Trigger the workflow manually:"
    echo "- Go to: https://github.com/$(git config --get remote.origin.url | sed -E 's#(git@|https://)([^/:]+)[:/]([^/.]+/[^.]+)(\.git)?#\2/\3#')/actions/workflows/release.yml"
    echo "- Click 'Run workflow', set tag to $TAG_VERSION, and run."
  fi
  exit 0
fi

# Standard release path (major/minor/patch)

# Check if git is clean
if [ -n "$(git status --porcelain)" ]; then
    print_error "Working directory is not clean. Please commit or stash your changes first."
    exit 1
fi

# Get current version from pubspec.yaml
CURRENT_VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //')
print_status "Current version: $CURRENT_VERSION"

# Parse version components
IFS='.' read -ra VERSION_PARTS <<< "${CURRENT_VERSION%%+*}"
MAJOR=${VERSION_PARTS[0]}
MINOR=${VERSION_PARTS[1]}
PATCH=${VERSION_PARTS[2]}

# Determine release type
RELEASE_TYPE=$ACTION

case $RELEASE_TYPE in
    major)
        NEW_MAJOR=$((MAJOR + 1))
        NEW_MINOR=0
        NEW_PATCH=0
        ;;
    minor)
        NEW_MAJOR=$MAJOR
        NEW_MINOR=$((MINOR + 1))
        NEW_PATCH=0
        ;;
    patch)
        NEW_MAJOR=$MAJOR
        NEW_MINOR=$MINOR
        NEW_PATCH=$((PATCH + 1))
        ;;
    *)
        print_error "Invalid command. Use: major | minor | patch | rebuild [vX.Y.Z]"
        exit 1
        ;;
esac

NEW_VERSION="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
TAG_VERSION="v$NEW_VERSION"

print_status "New version: $NEW_VERSION"
print_status "Tag version: $TAG_VERSION"

echo
read -p "Do you want to create release $TAG_VERSION? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warning "Release cancelled"
    exit 0
fi

# Get current build number
CURRENT_BUILD=$(echo "$CURRENT_VERSION" | awk -F'+' '{print $2}')
if [ -z "$CURRENT_BUILD" ]; then
    CURRENT_BUILD=1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))

# Update pubspec.yaml with new version and incremented build number
print_status "Updating pubspec.yaml to version: $NEW_VERSION+$NEW_BUILD"
sed -i.bak "s/^version: .*/version: $NEW_VERSION+$NEW_BUILD/" pubspec.yaml
rm pubspec.yaml.bak

# Generate Fastlane changelogs
print_status "Generating Fastlane changelogs..."
LINK="https://github.com/cogwheel0/conduit/releases/tag/$TAG_VERSION"

# Android changelog (default only)
ANDROID_CHANGELOG_DIR="android/fastlane/metadata/android/en-US/changelogs"
mkdir -p "$ANDROID_CHANGELOG_DIR"
echo "$LINK" > "$ANDROID_CHANGELOG_DIR/default.txt"

# iOS app version and release notes in Deliverfile
IOS_DELIVERFILE="ios/fastlane/Deliverfile"
if [ ! -f "$IOS_DELIVERFILE" ]; then
    print_error "Missing iOS Fastlane Deliverfile: $IOS_DELIVERFILE"
    exit 1
fi

print_status "Updating iOS Deliverfile with app version and release notes..."
NEW_VERSION="$NEW_VERSION" LINK="$LINK" perl -0pi.bak -e '
  s/app_version\("[^"]*"\)/app_version("$ENV{NEW_VERSION}")/g;
  if (!/app_version\("/) {
    s/(skip_metadata\([^\n]*\)\n)/$1app_version("$ENV{NEW_VERSION}")\n/;
  }
  s/'\''default'\'' => "[^"]*"/'\''default'\'' => "$ENV{LINK}"/g;
' "$IOS_DELIVERFILE"
rm "${IOS_DELIVERFILE}.bak"

# Commit changes
print_status "Committing changes..."
git add pubspec.yaml
git commit -m "chore: bump version to $NEW_VERSION"

git push origin main

# Create and push tag
print_status "Creating tag $TAG_VERSION..."
git tag -a "$TAG_VERSION" -m "Release $TAG_VERSION"
git push origin "$TAG_VERSION"

print_status "Release $TAG_VERSION created and pushed! CI will handle the build and GitHub release."

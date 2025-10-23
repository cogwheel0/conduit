#!/bin/bash

# Conduit Mobile Release Script (GitButler-compatible, CI-driven)
# Usage:
#   ./scripts/release.sh [major|minor|patch]
#   ./scripts/release.sh rebuild [vX.Y.Z]   # Rebuild existing tag, bump build number only, update same release assets
#
# Note: This script is compatible with GitButler. It only updates pubspec.yaml
# and instructs you to commit changes through GitButler. The CI workflow is
# triggered automatically when you push the tag through GitButler.

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
    print_status "✅ Workflow dispatched. Track progress in GitHub Actions."
    print_status ""
    print_status "📊 View workflow progress at:"
    print_status "   https://github.com/$(git config --get remote.origin.url | sed -E 's#(git@|https://)([^/:]+)[:/]([^/.]+/[^.]+)(\.git)?#\2/\3#')/actions"
  else
    print_warning "GitHub CLI (gh) not found. Trigger the workflow manually:"
    echo ""
    echo "📝 Manual workflow trigger steps:"
    echo "   1. Go to: https://github.com/$(git config --get remote.origin.url | sed -E 's#(git@|https://)([^/:]+)[:/]([^/.]+/[^.]+)(\.git)?#\2/\3#')/actions/workflows/release.yml"
    echo "   2. Click 'Run workflow'"
    echo "   3. Set tag to: $TAG_VERSION"
    echo "   4. Set 'Remove existing assets' to: true"
    echo "   5. Click 'Run workflow' button"
  fi
  exit 0
fi

# Standard release path (major/minor/patch)

# Note: GitButler manages git state, so we skip the clean check

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

print_status ""
print_status "✅ Version bumped to $NEW_VERSION+$NEW_BUILD in pubspec.yaml"
print_status ""
print_status "📝 NEXT STEPS (via GitButler):"
print_status "   1. Review the changes in GitButler"
print_status "   2. Commit the pubspec.yaml change with message: 'chore: bump version to $NEW_VERSION'"
print_status "   3. Push the commit to the main branch"
print_status "   4. Create and push tag: $TAG_VERSION"
print_status "      - In GitButler, you can create a tag from the commit"
print_status "      - Or use: git tag -a '$TAG_VERSION' -m 'Release $TAG_VERSION' && git push origin '$TAG_VERSION'"
print_status ""
print_status "🚀 Once the tag is pushed, GitHub Actions will automatically:"
print_status "   - Build Android APKs and AAB"
print_status "   - Build iOS IPA"
print_status "   - Create a GitHub release with all artifacts"
print_status ""

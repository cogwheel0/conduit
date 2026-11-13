#!/bin/bash
# Publishes appcast.xml to the hosting release.env names (APPCAST_HOSTING),
# so the feed URL every installed copy reads (SUFeedURL) serves it.
#
#   desktop/packaging/macos/publish-appcast.sh APPCAST.xml [--push]
#
# Without --push it only says what it would do. With --push it needs `gh`
# signed in (GH_TOKEN in CI) with contents: write on RELEASE_REPO.
#
#   release-asset  uploads appcast.xml to the fixed release APPCAST_RELEASE_TAG
#                  (made once, as a prerelease so it never becomes the
#                  repository's "Latest"), replacing the previous file
#   pages          commits desktop/appcast.xml to the gh-pages branch
#                  (Pages must serve that branch)
#   branch         commits appcast.xml to APPCAST_BRANCH
#
# Why not `releases/latest/download/appcast.xml`: "latest" skips
# prereleases (every beta) and points at the newest stable release of the
# whole repository, which is usually the mobile app's.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

xml="${1:-}"
push=0
[ "${2:-}" = "--push" ] && push=1
[ -f "$xml" ] || die "usage: publish-appcast.sh APPCAST.xml [--push]"
xmllint --noout "$xml"
url="$(appcast_url)"

run() {
  if [ "$push" = 1 ]; then "$@"; else printf 'would run:'; printf ' %q' "$@"; printf '\n'; fi
}

commit_to_branch() {
  local branch="$1" path="$2" clone
  clone="$(mktemp -d "${TMPDIR:-/tmp}/conduit-appcast.XXXXXX")"
  if [ "$push" = 0 ]; then
    printf 'would commit %s as %s on branch %s of %s\n' "$xml" "$path" "$branch" "$RELEASE_REPO"
    return
  fi
  local remote="https://github.com/$RELEASE_REPO.git"
  if git ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
    gh repo clone "$RELEASE_REPO" "$clone" -- --depth 1 --branch "$branch"
  else
    # A new orphan branch holding only the feed.
    gh repo clone "$RELEASE_REPO" "$clone" -- --depth 1
    git -C "$clone" switch --orphan "$branch"
  fi
  mkdir -p "$clone/$(dirname "$path")"
  cp "$xml" "$clone/$path"
  git -C "$clone" add "$path"
  git -C "$clone" -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -m "Update the desktop appcast" || {
    log "appcast unchanged"
    return
  }
  git -C "$clone" push origin "HEAD:$branch"
}

case "$APPCAST_HOSTING" in
  release-asset)
    if [ "$push" = 1 ] && ! gh release view "$APPCAST_RELEASE_TAG" -R "$RELEASE_REPO" >/dev/null 2>&1; then
      gh release create "$APPCAST_RELEASE_TAG" -R "$RELEASE_REPO" --prerelease --latest=false \
        --title "Conduit Desktop update feed" \
        --notes "Sparkle's appcast for Conduit Desktop (appcast.xml). Installed copies read it from this fixed address; do not delete this release or its tag."
    elif [ "$push" = 0 ]; then
      printf 'would create the prerelease %s on %s if it does not exist\n' "$APPCAST_RELEASE_TAG" "$RELEASE_REPO"
    fi
    run gh release upload "$APPCAST_RELEASE_TAG" "$xml" -R "$RELEASE_REPO" --clobber
    ;;
  pages) commit_to_branch gh-pages desktop/appcast.xml ;;
  branch) commit_to_branch "$APPCAST_BRANCH" appcast.xml ;;
  *) die "APPCAST_HOSTING must be release-asset, pages or branch" ;;
esac
log "feed URL: $url"

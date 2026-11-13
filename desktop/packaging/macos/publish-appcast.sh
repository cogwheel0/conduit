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
# Why not `releases/latest/download/appcast.xml`: "latest" is the newest
# release of the whole repository, which is usually the mobile app's.
#
# release-desktop.yml runs this when a desktop-v* draft is published (job
# `feed`), with the appcast the build signed and attached to the draft.
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
  # The checkout keeps no credentials: git pushes with gh's (GH_TOKEN).
  gh auth setup-git
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

# Replaces appcast.xml on the feed release without ever losing the live
# one: the current file is first renamed appcast.previous.xml (replacing an
# older copy), the new one uploaded, and on a failed upload the previous one
# is renamed back. Every lookup that fails stops.
replace_feed_asset() {
  local new="$1" staged assets current previous
  staged="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed.XXXXXX")"
  cp "$new" "$staged/appcast.xml"
  assets="$(gh api "repos/$RELEASE_REPO/releases/tags/$APPCAST_RELEASE_TAG" \
    --jq '.assets[] | "\(.id) \(.name)"')" || die "could not list the feed release's files"
  current="$(printf '%s\n' "$assets" | awk '$2 == "appcast.xml" {print $1}')"
  previous="$(printf '%s\n' "$assets" | awk '$2 == "appcast.previous.xml" {print $1}')"
  if [ -n "$current" ]; then
    if [ -n "$previous" ]; then
      gh api -X DELETE "repos/$RELEASE_REPO/releases/assets/$previous" >/dev/null ||
        die "could not remove the older appcast.previous.xml"
    fi
    gh api -X PATCH "repos/$RELEASE_REPO/releases/assets/$current" -f name=appcast.previous.xml >/dev/null ||
      die "could not keep the live appcast.xml aside; nothing was changed"
  fi
  if ! gh release upload "$APPCAST_RELEASE_TAG" "$staged/appcast.xml" -R "$RELEASE_REPO"; then
    if [ -n "$current" ]; then
      gh api -X PATCH "repos/$RELEASE_REPO/releases/assets/$current" -f name=appcast.xml >/dev/null ||
        die "the upload failed and appcast.previous.xml could not be renamed back: rename it to appcast.xml"
    fi
    die "the new appcast did not upload; the live one is unchanged"
  fi
  log "appcast.xml replaced (the last one is kept as appcast.previous.xml)"
}

case "$APPCAST_HOSTING" in
  release-asset)
    if [ "$push" = 0 ]; then
      printf 'would create the prerelease %s on %s if it does not exist\n' "$APPCAST_RELEASE_TAG" "$RELEASE_REPO"
      printf 'would keep the current appcast.xml as appcast.previous.xml, then upload %s\n' "$xml"
    else
      state="$(release_exists "$APPCAST_RELEASE_TAG")"
      if [ "$state" = no ]; then
        gh release create "$APPCAST_RELEASE_TAG" -R "$RELEASE_REPO" --prerelease --latest=false \
          --title "Conduit Desktop update feed" \
          --notes "Sparkle's appcast for Conduit Desktop (appcast.xml). Installed copies read it from this fixed address; do not delete this release or its tag."
      fi
      replace_feed_asset "$xml"
    fi
    ;;
  pages) commit_to_branch gh-pages desktop/appcast.xml ;;
  branch) commit_to_branch "$APPCAST_BRANCH" appcast.xml ;;
  *) die "APPCAST_HOSTING must be release-asset, pages or branch" ;;
esac
log "feed URL: $url"

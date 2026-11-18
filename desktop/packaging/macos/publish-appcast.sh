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
#                  (a prerelease, so it never becomes the repository's
#                  "Latest"), replacing the previous file; the first time it
#                  is made as a draft and published only once its appcast.xml
#                  is uploaded and checked, so a failed first run is retried
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
# one, and with the fixed URL empty for as short a time as can be: the new
# file is uploaded first under another name (appcast.next.xml), then the
# live one is renamed appcast.previous.xml (replacing an older copy) and the
# new one renamed appcast.xml, two quick renames. A rename that fails puts
# the live one back. Every lookup that fails stops, and so does a feed
# release whose appcast.xml is missing while appcast.previous.xml is there
# (a publication that stopped half way: docs/RELEASING-DESKTOP.md).
replace_feed_asset() {
  local new="$1" staged assets current previous next uploaded
  staged="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed.XXXXXX")"
  cp "$new" "$staged/appcast.next.xml"
  assets="$(gh api "repos/$RELEASE_REPO/releases/tags/$APPCAST_RELEASE_TAG" \
    --jq '.assets[] | "\(.id) \(.name)"')" || die "could not list the feed release's files"
  current="$(printf '%s\n' "$assets" | awk '$2 == "appcast.xml" {print $1}')"
  previous="$(printf '%s\n' "$assets" | awk '$2 == "appcast.previous.xml" {print $1}')"
  next="$(printf '%s\n' "$assets" | awk '$2 == "appcast.next.xml" {print $1}')"
  if [ -z "$current" ] && [ -n "$previous" ]; then
    die "the feed release has appcast.previous.xml but no appcast.xml: a publication stopped half way; rename appcast.previous.xml to appcast.xml first (docs/RELEASING-DESKTOP.md)"
  fi
  if [ -n "$next" ]; then
    gh api -X DELETE "repos/$RELEASE_REPO/releases/assets/$next" >/dev/null ||
      die "could not remove a stale appcast.next.xml; nothing was changed"
  fi
  gh release upload "$APPCAST_RELEASE_TAG" "$staged/appcast.next.xml" -R "$RELEASE_REPO" ||
    die "the new appcast did not upload; the live one is unchanged"
  uploaded="$(gh api "repos/$RELEASE_REPO/releases/tags/$APPCAST_RELEASE_TAG" \
    --jq '.assets[] | select(.name == "appcast.next.xml") | .id')" ||
    die "could not find the uploaded appcast.next.xml; the live one is unchanged"
  [ -n "$uploaded" ] || die "the uploaded appcast.next.xml is not listed; the live one is unchanged"
  if [ -n "$current" ]; then
    if [ -n "$previous" ]; then
      gh api -X DELETE "repos/$RELEASE_REPO/releases/assets/$previous" >/dev/null ||
        die "could not remove the older appcast.previous.xml; the live one is unchanged"
    fi
    gh api -X PATCH "repos/$RELEASE_REPO/releases/assets/$current" -f name=appcast.previous.xml >/dev/null ||
      die "could not keep the live appcast.xml aside; the live one is unchanged"
  fi
  if ! gh api -X PATCH "repos/$RELEASE_REPO/releases/assets/$uploaded" -f name=appcast.xml >/dev/null; then
    if [ -n "$current" ]; then
      gh api -X PATCH "repos/$RELEASE_REPO/releases/assets/$current" -f name=appcast.xml >/dev/null ||
        die "the new appcast could not take the live name and appcast.previous.xml could not be renamed back: rename it to appcast.xml"
    fi
    die "the new appcast could not take the live name; the live one is unchanged"
  fi
  log "appcast.xml replaced (the last one is kept as appcast.previous.xml)"
}

# The feed release's state: published (live), draft (a first publication
# that stopped before publishing it; no installed copy reads a draft) or
# none. A lookup that fails stops.
feed_release_state() {
  local states
  states="$(gh api --paginate "repos/$RELEASE_REPO/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$APPCAST_RELEASE_TAG\") | if .draft then \"draft\" else \"published\" end")" ||
    die "could not list the releases of $RELEASE_REPO"
  case "$states" in
    *published*) printf 'published\n' ;;
    *draft*) printf 'draft\n' ;;
    *) printf 'none\n' ;;
  esac
}

# The first publication, which a failure never leaves half live: the feed
# release is made as a DRAFT (or the draft a failed run left is taken over),
# appcast.xml is uploaded to it, read back and compared, and only then is
# the release published. Until that last step nothing is at the feed URL,
# so the next run starts again from the draft.
first_feed_release() {
  local new="$1" state="$2" staged check
  staged="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed.XXXXXX")"
  check="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed-check.XXXXXX")"
  cp "$new" "$staged/appcast.xml"
  if [ "$state" = none ]; then
    gh release create "$APPCAST_RELEASE_TAG" -R "$RELEASE_REPO" --draft --prerelease --latest=false \
      --title "Conduit Desktop update feed" \
      --notes "Sparkle's appcast for Conduit Desktop (appcast.xml). Installed copies read it from this fixed address; do not delete this release or its tag." ||
      die "could not create the feed release as a draft; nothing is live"
  else
    log "taking over the draft feed release a failed run left"
  fi
  gh release upload "$APPCAST_RELEASE_TAG" "$staged/appcast.xml" -R "$RELEASE_REPO" --clobber ||
    die "the appcast did not upload to the draft feed release; nothing is live (run again)"
  gh release download "$APPCAST_RELEASE_TAG" -R "$RELEASE_REPO" -p appcast.xml -D "$check" ||
    die "could not read the appcast back from the draft feed release; nothing is live (run again)"
  cmp -s "$staged/appcast.xml" "$check/appcast.xml" ||
    die "the draft feed release's appcast.xml is not the one uploaded; nothing is live (run again)"
  gh release edit "$APPCAST_RELEASE_TAG" -R "$RELEASE_REPO" --draft=false --prerelease --latest=false ||
    die "could not publish the feed release; it stays a draft (run again)"
  log "the feed release $APPCAST_RELEASE_TAG is published with appcast.xml"
}

case "$APPCAST_HOSTING" in
  release-asset)
    if [ "$push" = 0 ]; then
      printf 'would publish %s on the feed release %s of %s: the first time as a draft first (published once its appcast.xml is checked), later by swapping it in\n' \
        "$xml" "$APPCAST_RELEASE_TAG" "$RELEASE_REPO"
    else
      state="$(feed_release_state)"
      case "$state" in
        published) replace_feed_asset "$xml" ;;
        *) first_feed_release "$xml" "$state" ;;
      esac
    fi
    ;;
  pages) commit_to_branch gh-pages desktop/appcast.xml ;;
  branch) commit_to_branch "$APPCAST_BRANCH" appcast.xml ;;
  *) die "APPCAST_HOSTING must be release-asset, pages or branch" ;;
esac
log "feed URL: $url"

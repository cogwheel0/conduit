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

# The name the feed release's file ID has now ("gone" once it no longer
# exists). A lookup that fails says so and returns 1: a state that cannot
# be read is never guessed.
asset_name() {
  local out
  if out="$(gh api "repos/$RELEASE_REPO/releases/assets/$1" --jq .name 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *"HTTP 404"*) printf 'gone\n' ;;
    *) warn "could not look up the feed release's file $1: $out"; return 1 ;;
  esac
}

# Renames the feed release's file ID to NAME. A request that fails may still
# have been applied (GitHub renamed it and the reply was lost), so the
# file's real name decides: 0 when it has NAME now, 1 when it does not, 2
# when its name cannot be read.
rename_asset() {
  gh api -X PATCH "repos/$RELEASE_REPO/releases/assets/$1" -f name="$2" >/dev/null 2>&1 && return 0
  local now
  now="$(asset_name "$1")" || return 2
  [ "$now" = "$2" ]
}

# Deletes the feed release's file ID, by the same rule: 0 once it is gone
# (a lost reply included), 1 when it is still there, 2 when unknown.
delete_asset() {
  gh api -X DELETE "repos/$RELEASE_REPO/releases/assets/$1" >/dev/null 2>&1 && return 0
  local now
  now="$(asset_name "$1")" || return 2
  [ "$now" = gone ]
}

# Replaces appcast.xml on the feed release without ever losing the live
# one, and with the fixed URL empty for as short a time as can be: the new
# file is uploaded first under a name of its run's own (appcast.next-….xml), then the
# live one is renamed appcast.previous.xml (replacing an older copy) and the
# new one renamed appcast.xml, two quick renames. A rename that fails puts
# the live one back. Every lookup that fails stops, and so does a feed
# release whose appcast.xml is missing while appcast.previous.xml is there
# (a publication that stopped half way: docs/RELEASING-DESKTOP.md).
# A request whose reply is lost is judged by the file's real state
# (rename_asset, delete_asset): a rename GitHub applied is never reported as
# not done, nor undone by a wrong recovery.
replace_feed_asset() {
  local new="$1" staged assets current previous uploaded rc
  # Staged under a name of this run's own, and promoted by the id of what
  # this run uploaded: a publication run by hand alongside (outside CI's
  # queue) never has its file promoted by this one, nor this one's by it,
  # and neither removes the other's staged file.
  local stage="appcast.next-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$.xml"
  staged="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed.XXXXXX")" && [ -d "$staged" ] ||
    die "could not make a scratch folder; nothing was changed"
  cp "$new" "$staged/$stage" || die "could not stage the new appcast; nothing was changed"
  assets="$(gh api "repos/$RELEASE_REPO/releases/tags/$APPCAST_RELEASE_TAG" \
    --jq '.assets[] | "\(.id) \(.name)"')" || die "could not list the feed release's files"
  current="$(printf '%s\n' "$assets" | awk '$2 == "appcast.xml" {print $1}')"
  previous="$(printf '%s\n' "$assets" | awk '$2 == "appcast.previous.xml" {print $1}')"
  if [ -z "$current" ] && [ -n "$previous" ]; then
    die "the feed release has appcast.previous.xml but no appcast.xml: a publication stopped half way; rename appcast.previous.xml to appcast.xml first (docs/RELEASING-DESKTOP.md)"
  fi
  gh release upload "$APPCAST_RELEASE_TAG" "$staged/$stage" -R "$RELEASE_REPO" ||
    die "the new appcast did not upload; the live one is unchanged"
  uploaded="$(gh api "repos/$RELEASE_REPO/releases/tags/$APPCAST_RELEASE_TAG" \
    --jq ".assets[] | select(.name == \"$stage\") | .id")" ||
    die "could not find the uploaded $stage; the live one is unchanged"
  [ -n "$uploaded" ] && [ "$(printf '%s\n' "$uploaded" | wc -l | tr -d ' ')" = 1 ] ||
    die "the uploaded $stage is not listed once; the live one is unchanged"
  if [ -n "$current" ]; then
    if [ -n "$previous" ]; then
      delete_asset "$previous" || die "could not remove the older appcast.previous.xml; the live one is unchanged"
    fi
    rc=0
    rename_asset "$current" appcast.previous.xml || rc=$?
    case "$rc" in
      0) ;;
      1) die "could not keep the live appcast.xml aside; the live one is unchanged" ;;
      *) die "could not tell whether the live appcast.xml was renamed: check the feed release (appcast.xml must be there; docs/RELEASING-DESKTOP.md)" ;;
    esac
  fi
  rc=0
  rename_asset "$uploaded" appcast.xml || rc=$?
  case "$rc" in
    0) ;;
    1)
      if [ -n "$current" ]; then
        rc=0
        rename_asset "$current" appcast.xml || rc=$?
        case "$rc" in
          0) ;;
          1) die "the new appcast could not take the live name and appcast.previous.xml could not be renamed back: rename it to appcast.xml" ;;
          *) die "the new appcast could not take the live name, and whether appcast.previous.xml was renamed back cannot be read: check the feed release (appcast.xml must be there)" ;;
        esac
      fi
      die "the new appcast could not take the live name; the live one is unchanged"
      ;;
    *) die "could not tell whether the new appcast took the live name: check the feed release (appcast.xml must be there; docs/RELEASING-DESKTOP.md)" ;;
  esac
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
  staged="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed.XXXXXX")" && [ -d "$staged" ] ||
    die "could not make a scratch folder; nothing is live"
  check="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed-check.XXXXXX")" && [ -d "$check" ] ||
    die "could not make a scratch folder; nothing is live"
  cp "$new" "$staged/appcast.xml" || die "could not stage the appcast; nothing is live"
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

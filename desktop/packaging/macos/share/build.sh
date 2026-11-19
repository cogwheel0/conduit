# The Share extension (ConduitShare.appex) and the Services menu's words,
# for bundle.sh (sourced after lib.sh, not run). Bash 3.2.
#
#   share_build APP APP_ID NAME VERSION BUILD
#       compiles the extension with swiftc into APP/Contents/PlugIns,
#       fills its Info.plist and writes its Localizable.strings
#   share_entitlements APP_ID OUT
#       the extension's entitlements for APP_ID, written to OUT
#   services_strings APP
#       APP/Contents/Resources/<lang>.lproj/ServicesMenu.strings, the
#       Services menu titles (Info.plist NSServices) in every language
#   share_verify APP APP_ID
#       checks the embedded extension (bundle.sh verify, smoke.sh)
#
# No Xcode project: swiftc builds the one executable, linked with
# NSExtensionMain as its entry point as Xcode links app extensions.

SHARE_DIR="$PACKAGING_DIR/share"
SHARE_APPEX=ConduitShare.appex
SHARE_EXECUTABLE=ConduitShare

# The extension's words: .strings key = ARB key (% = format string).
SHARE_STRINGS=(
  cancel=cancel
  open=desktopOpenInConduit
  message=desktopMessageField
  messagePlaceholder=desktopShareSheetMessage
  items=desktopShareSheetItems
  nothing=desktopShareSheetNothing
  failed=desktopShareSheetFailed
  tooLarge=desktopOpenFileTooLarge%
)

# The Services menu titles: Info.plist's NSMenuItem default = ARB key.
SERVICES_STRINGS=(
  "Ask Conduit=askConduitAction"
  "New Conduit Chat With Selection=desktopServicesNewChat"
)

native_strings() {
  local out="$1" table="$2"
  shift 2
  python3 "$PACKAGING_DIR/native_strings.py" table "$REPO_ROOT/lib/l10n" "$out" "$table" "$@" >&2
}

share_build() {
  local app="$1" app_id="$2" name="$3" version="$4" build="$5"
  local appex="$app/Contents/PlugIns/$SHARE_APPEX"
  mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
  log "building the Share extension (swiftc)"
  xcrun swiftc -O -whole-module-optimization -swift-version 5 \
    -target "$ARCH-apple-macos$MACOS_MIN" \
    -application-extension -parse-as-library -module-name "$SHARE_EXECUTABLE" \
    -o "$appex/Contents/MacOS/$SHARE_EXECUTABLE" \
    "$SHARE_DIR/ShareInbox.swift" "$SHARE_DIR/ShareViewController.swift" \
    -Xlinker -e -Xlinker _NSExtensionMain
  sed -e "s/@APP_BUNDLE_ID@/$app_id/g" \
    -e "s/@BUNDLE_NAME@/$name/" \
    -e "s/@VERSION@/$version/" \
    -e "s/@BUILD@/$build/" \
    -e "s/@MACOS_MIN@/$MACOS_MIN/" \
    "$SHARE_DIR/Info.plist" >"$appex/Contents/Info.plist"
  plutil -lint -s "$appex/Contents/Info.plist"
  printf 'XPC!????' >"$appex/Contents/PkgInfo"
  native_strings "$appex/Contents/Resources" Localizable.strings "${SHARE_STRINGS[@]}"
}

share_entitlements() {
  sed -e "s/@APP_BUNDLE_ID@/$1/g" "$SHARE_DIR/Share.entitlements" >"$2"
  plutil -lint -s "$2"
}

services_strings() {
  native_strings "$1/Contents/Resources" ServicesMenu.strings "${SERVICES_STRINGS[@]}"
}

# Prints problems as "FAIL …" lines; returns 1 if there were any.
share_verify() {
  local app="$1" app_id="$2" bad=0
  local appex="$app/Contents/PlugIns/$SHARE_APPEX"
  local plist="$appex/Contents/Info.plist" v
  problem() {
    printf '\033[31mFAIL\033[0m %s\n' "$*"
    bad=1
  }
  [ -d "$appex" ] || {
    problem "no $SHARE_APPEX in Contents/PlugIns"
    return 1
  }
  plutil -lint -s "$plist" || problem "$SHARE_APPEX Info.plist does not lint"
  v="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$plist" 2>/dev/null)"
  [ "$v" = "com.apple.share-services" ] || problem "$SHARE_APPEX extension point '$v'"
  v="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)"
  [ "$v" = "$app_id.share" ] || problem "$SHARE_APPEX id '$v' (want $app_id.share)"
  v="$(plutil -extract ConduitAppBundleIdentifier raw -o - "$plist" 2>/dev/null)"
  [ "$v" = "$app_id" ] || problem "$SHARE_APPEX hands shares to '$v' (want $app_id)"
  v="$(lipo -archs "$appex/Contents/MacOS/$SHARE_EXECUTABLE" 2>/dev/null)"
  [ "$v" = "$ARCH" ] || problem "$SHARE_EXECUTABLE is '$v'"
  # Whole outputs first: `grep -q` on a pipe ends it early, and pipefail
  # then fails the check.
  local ent info
  ent="$(codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)"
  grep -A1 '<key>com.apple.security.app-sandbox</key>' <<<"$ent" | grep -q '<true/>' ||
    problem "$SHARE_APPEX is not sandboxed"
  grep -Fq "<string>/Library/Caches/$app_id.share-inbox/</string>" <<<"$ent" ||
    problem "$SHARE_APPEX cannot write the inbox for $app_id"
  codesign --verify --strict "$appex" 2>/dev/null || problem "$SHARE_APPEX signature"
  info="$(codesign -dv "$appex" 2>&1)"
  grep -q 'flags=.*runtime' <<<"$info" || problem "$SHARE_APPEX has no hardened runtime"
  local count
  count="$(find "$appex/Contents/Resources" -name Localizable.strings | wc -l | tr -d ' ')"
  [ "$count" -ge 14 ] || problem "$SHARE_APPEX has $count Localizable.strings (want 14)"
  count="$(find "$app/Contents/Resources" -maxdepth 2 -name ServicesMenu.strings | wc -l | tr -d ' ')"
  [ "$count" -ge 14 ] || problem "$count ServicesMenu.strings (want 14)"
  v="$(plutil -extract NSServices raw -o - "$app/Contents/Info.plist" 2>/dev/null)"
  [ "$v" = "2" ] || problem "NSServices: '$v' items (want 2)"
  [ "$bad" = 0 ]
}

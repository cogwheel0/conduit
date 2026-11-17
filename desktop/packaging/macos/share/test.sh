#!/bin/bash
# Runs the Share extension's inbox tests (tests/InboxTests.swift) and
# type-checks the extension and its preview (preview.sh), without a bundle.
#
#   desktop/packaging/macos/share/test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/conduit-share-test.XXXXXX")"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -o "$out/InboxTests" \
  "$here/ShareInbox.swift" "$here/tests/InboxTests.swift"
"$out/InboxTests" "$here/tests/manifest-v1.json"
xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-macos14.0 \
  -application-extension -parse-as-library -module-name ConduitShare \
  "$here/ShareInbox.swift" "$here/ShareViewController.swift"
xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-macos14.0 \
  -parse-as-library -D SHARE_PREVIEW -module-name SharePreview \
  "$here/ShareInbox.swift" "$here/ShareViewController.swift" "$here/tests/SharePreview.swift"
echo "share extension and its preview: type-check"

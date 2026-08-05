#!/usr/bin/env bash
set -euo pipefail

android_limit=$((30 * 1024 * 1024))
ios_limit=$((35 * 1024 * 1024))
runtime_name="libconduit_chatgpt_runtime.so"
failed=0

for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
  if [ ! -f "$apk" ]; then
    echo "missing Android split release APKs" >&2
    exit 1
  fi
  size="$(unzip -p "$apk" "lib/*/$runtime_name" | gzip -c | wc -c | tr -d ' ')"
  abi="${apk#build/app/outputs/flutter-apk/app-}"
  abi="${abi%-release.apk}"
  echo "ChatGPT runtime $abi compressed bytes: $size"
  if [ "$size" -gt "$android_limit" ]; then
    echo "ChatGPT runtime exceeds the 30 MiB Android $abi budget" >&2
    failed=1
  fi
done

ios_binary="build/ios/iphoneos/Runner.app/Frameworks/conduit_chatgpt_runtime.framework/conduit_chatgpt_runtime"
if [ ! -f "$ios_binary" ]; then
  echo "missing unsigned iOS release runtime" >&2
  exit 1
fi
ios_size="$(gzip -c "$ios_binary" | wc -c | tr -d ' ')"
echo "ChatGPT runtime iOS compressed bytes: $ios_size"
if [ "$ios_size" -gt "$ios_limit" ]; then
  echo "ChatGPT runtime exceeds the 35 MiB iOS budget" >&2
  failed=1
fi

exit "$failed"

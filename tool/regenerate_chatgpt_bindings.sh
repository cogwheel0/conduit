#!/usr/bin/env bash
set -euo pipefail

required_version="$(sed -nE 's/^  flutter_rust_bridge: ([0-9.]+)$/\1/p' pubspec.yaml)"
if [ -z "$required_version" ]; then
  echo "flutter_rust_bridge is not pinned in pubspec.yaml" >&2
  exit 1
fi
if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  echo "flutter_rust_bridge_codegen $required_version is required" >&2
  exit 1
fi
installed_version="$(flutter_rust_bridge_codegen --version | awk '{print $NF}')"
if [ "$installed_version" != "$required_version" ]; then
  echo "flutter_rust_bridge_codegen $required_version is required (found $installed_version)" >&2
  exit 1
fi

flutter_rust_bridge_codegen generate
cargo fmt --manifest-path native/chatgpt_runtime/Cargo.toml --all

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="$script_dir/.build"
module_cache_dir="$output_dir/module-cache"
architecture="$(uname -m)"
mkdir -p "$output_dir"
mkdir -p "$module_cache_dir"

CLANG_MODULE_CACHE_PATH="$module_cache_dir" xcrun --sdk macosx swiftc \
  -O \
  -target "$architecture-apple-macosx13.0" \
  -module-cache-path "$module_cache_dir" \
  -framework ApplicationServices \
  "$script_dir/HotKeyInjector.swift" \
  -o "$output_dir/hotkey-injector"

echo "built=$output_dir/hotkey-injector"

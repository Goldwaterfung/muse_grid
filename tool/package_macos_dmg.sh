#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <app-bundle> <version> [output-directory]" >&2
  exit 2
}

[[ $# -ge 2 && $# -le 3 ]] || usage

app_bundle=$1
version=$2
output_dir=${3:-build/installer}
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use MAJOR.MINOR.PATCH format: $version" >&2
  exit 2
fi

if [[ "$app_bundle" != /* ]]; then
  app_bundle="$repo_root/$app_bundle"
fi
if [[ ! -d "$app_bundle" || "$app_bundle" != *.app ]]; then
  echo "App bundle does not exist or is not a .app directory: $app_bundle" >&2
  exit 1
fi

command -v ditto >/dev/null || {
  echo "ditto is required to package the macOS app." >&2
  exit 1
}
command -v hdiutil >/dev/null || {
  echo "hdiutil is required to create a macOS disk image." >&2
  exit 1
}

if [[ "$output_dir" != /* ]]; then
  output_dir="$repo_root/$output_dir"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/muse-grid-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_bundle" "$staging_dir/MuseGrid.app"
ln -s /Applications "$staging_dir/Applications"

dmg_path="$output_dir/muse-grid-macos-$version.dmg"
hdiutil create -quiet -volname MuseGrid -srcfolder "$staging_dir" \
  -ov -format UDZO "$dmg_path"
hdiutil verify -quiet "$dmg_path"

echo "Created $dmg_path"

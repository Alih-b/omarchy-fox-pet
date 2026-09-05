#!/usr/bin/env bash
set -euo pipefail

# Stage a complete release before making it discoverable. Backups must live
# outside plugins/: the shell discovers manifest IDs, not directory names.
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugins_dir="${HOME:?}/.config/omarchy/plugins"
target="$plugins_dir/fox-pet"
backup_root="$HOME/.local/state/omarchy/fox-pet/plugin-backups"

command -v jq >/dev/null
command -v omarchy-shell >/dev/null
jq -e '.id == "fox-pet"' "$repo_dir/manifest.json" >/dev/null
for file in Service.qml Panel.qml SpriteView.qml BarWidget.qml assets/pet.json assets/spritesheet.webp; do
  [[ -f "$repo_dir/$file" ]] || { echo "Missing release file: $file" >&2; exit 1; }
done
if [[ -e "$target" || -L "$target" ]]; then
  [[ -f "$target/manifest.json" ]] && jq -e '.id == "fox-pet"' "$target/manifest.json" >/dev/null || {
    echo "Refusing to replace an unrelated directory: $target" >&2; exit 1;
  }
fi

mkdir -p -- "$plugins_dir" "$backup_root"
stage=$(mktemp -d "$plugins_dir/.fox-pet.install.XXXXXXXX")
# Distinct URLs also invalidate Qt's cache of sibling QML components.
release_hash=$(cd -- "$repo_dir" && sha256sum -- *.qml manifest.json assets/pet.json assets/spritesheet.webp | sha256sum)
release="release-${release_hash:0:16}"
mkdir -- "$stage/$release"
cp -- "$repo_dir/"*.qml "$stage/$release/"
cp -a -- "$repo_dir/assets" "$stage/$release/assets"
jq --arg release "$release/" '.entryPoints |= with_entries(.value = $release + .value)' \
  "$repo_dir/manifest.json" > "$stage/manifest.json"
backup=$(mktemp -d "$backup_root/install.XXXXXXXX")
published=false
archived=()

finish() {
  local status=$?
  if (( status != 0 )) && [[ $published == false ]]; then
    for name in "${archived[@]}"; do
      if [[ ! -e "$plugins_dir/$name" && ! -L "$plugins_dir/$name" ]]; then
        mv -T -- "$backup/$name" "$plugins_dir/$name"
      fi
    done
    echo "Install failed; previous plugins restored. Staging retained at $stage" >&2
  fi
}
trap finish EXIT

shopt -s nullglob dotglob
for candidate in "$plugins_dir"/*; do
  [[ "$candidate" != "$stage" && -f "$candidate/manifest.json" ]] || continue
  if jq -e '.id == "fox-pet"' "$candidate/manifest.json" >/dev/null 2>&1; then
    name=${candidate##*/}
    mv -T -- "$candidate" "$backup/$name"
    archived+=("$name")
  fi
done
mv -T -- "$stage" "$target"
published=true
echo "Installed fox-pet $(jq -r .version "$target/manifest.json") at $target"
echo "Previous copies preserved at $backup"
omarchy-shell shell rescanPlugins
for (( attempt = 0; attempt < 15; attempt++ )); do
  running_build=$(omarchy-shell fox-pet build 2>/dev/null || true)
  if jq -e --arg path "/fox-pet/$release/Service.qml" \
      '.source | endswith($path)' <<< "$running_build" >/dev/null 2>&1; then
    echo "Verified running release: $release"
    exit 0
  fi
  sleep 0.2
done
echo "Files installed, but the shell did not load $release. Try: omarchy restart shell" >&2
exit 1

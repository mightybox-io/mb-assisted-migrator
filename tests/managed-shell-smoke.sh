#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/mb-managed-shell-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
if [[ "${1:-}" == --require-no-dev-fd ]]; then
  [[ ! -e /dev/fd ]] || { printf '/dev/fd must be absent for this scenario\n' >&2; exit 1; }
fi
mkdir -p "$T/source/wp-content/mu-plugins" "$T/out" "$T/tmp"
printf '<?php\n' > "$T/source/wp-config.php"
printf core > "$T/source/index.php"
printf artifact > "$T/source/wordpress-package-test.tar.gz"
printf content > "$T/source/wp-content/custom.txt"
for name in '.htaccess' 'space name' $'line\nbreak' '--checkpoint=1' 'back\slash'; do
  printf '%s' "$name" > "$T/source/$name"
done
ln -s 'space name' "$T/source/root-link"
export TMPDIR="$T/tmp"
bash "$ROOT_DIR/lib/remote-source.sh" archive-root "$T/source" > "$T/root.tar.gz"
gzip -t "$T/root.tar.gz"
tar -xzf "$T/root.tar.gz" -C "$T/out"
for name in '.htaccess' 'space name' $'line\nbreak' '--checkpoint=1' 'back\slash'; do
  cmp "$T/source/$name" "$T/out/$name"
done
for name in wp-config.php index.php wordpress-package-test.tar.gz wp-content root-link; do
  [[ ! -e "$T/out/$name" && ! -L "$T/out/$name" ]]
done
bash "$ROOT_DIR/lib/remote-source.sh" archive-files "$T/source" > "$T/all.tar.gz"
tar -xzf "$T/all.tar.gz" -C "$T/out"
cmp "$T/source/wp-content/custom.txt" "$T/out/wp-content/custom.txt"
mkdir -p "$T/empty/wp-content"
printf '<?php\n' > "$T/empty/wp-config.php"
bash "$ROOT_DIR/lib/remote-source.sh" archive-root "$T/empty" > "$T/empty.tar.gz"
[[ -z "$(tar -tzf "$T/empty.tar.gz")" ]]
# Invoke the actual normalization scanner independently of WordPress/database
# preflight: these checks concern directory enumeration, not WP-CLI behavior.
sed '/^case "$command_name" in/,$d' "$ROOT_DIR/lib/remote-source.sh" > "$T/scan.sh"
printf '\nnormalization_scan\n' >> "$T/scan.sh"
mkdir "$T/source/wp-content/mu-plugins/wpengine-common"
printf unknown > "$T/source/wp-content/mu-plugins/"$'custom\nplugin.php'
bash "$T/scan.sh" scan "$T/source" auto wp-engine-v1 \
  'wpengine.mu.wpengine-common-v1|mu-plugins/wpengine-common' > "$T/normalization"
grep -qx 'normalization_rule_ids=wpengine.mu.wpengine-common-v1' "$T/normalization"
grep -qx 'normalization_unknown_count=1' "$T/normalization"
# An enumeration error must fail closed rather than emit a partial archive.
mkdir "$T/bin"
printf '#!/usr/bin/env bash\nexit 23\n' > "$T/bin/find"
chmod +x "$T/bin/find"
if PATH="$T/bin:$PATH" bash "$ROOT_DIR/lib/remote-source.sh" archive-root "$T/source" > "$T/failed.tar.gz" 2> "$T/failed.log"; then
  printf 'Failed enumeration unexpectedly succeeded\n' >&2; exit 1
fi
[[ ! -s "$T/failed.tar.gz" ]]
grep -q 'could not enumerate source root files' "$T/failed.log"
[[ -z "$(find "$T/tmp" -mindepth 1 -print -quit)" ]]
printf 'Managed-shell collection smoke passed.\n'

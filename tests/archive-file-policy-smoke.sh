#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${ARCHIVE_POLICY_HELPER:-$ROOT_DIR/lib/archive-file-policy.php}"
T="$(mktemp -d "${TMPDIR:-/tmp}/mb-archive-policy.XXXXXX")"
trap 'rm -rf "$T"' EXIT
sha="$(printf archive | sha256sum | awk '{print $1}')"
mkdir -p "$T/source/plugins/sample" "$T/source/themes/managed" "$T/source/uploads" "$T/target/plugins" "$T/target/themes" "$T/managed" "$T/other"
printf source-theme > "$T/source/themes/managed/style.css"
printf platform-theme > "$T/managed/style.css"
printf copied > "$T/source/plugins/sample/plugin.php"
printf media > "$T/source/uploads/image.png"
ln -s "$T/managed" "$T/target/themes/managed"
policy="$T/policy.json"
run() { php "$helper" "$1" "$policy" "$T/source" "$T/target" "$sha"; }
refuse() { if "$@" > "$T/refusal.log" 2>&1; then echo 'Expected refusal' >&2; exit 1; fi; }
run capture
mkdir -p "$T/target/plugins/sample" "$T/target/uploads"
cp "$T/source/plugins/sample/plugin.php" "$T/target/plugins/sample/plugin.php"
cp "$T/source/uploads/image.png" "$T/target/uploads/image.png"
run verify > "$T/pass.txt"
grep -Fxq 'preserved_paths_count=1' "$T/pass.txt"
grep -Fxq 'migrated_files_count=2' "$T/pass.txt"
grep -Fxq 'media_count=1' "$T/pass.txt"
refuse run capture
printf corrupt > "$T/target/uploads/image.png"
refuse run verify
cp "$T/source/uploads/image.png" "$T/target/uploads/image.png"
printf altered > "$T/managed/style.css"
refuse run verify
printf platform-theme > "$T/managed/style.css"
cp "$T/managed/style.css" "$T/other/style.css"
rm "$T/target/themes/managed"
ln -s "$T/other" "$T/target/themes/managed"
refuse run verify
rm "$T/target/themes/managed"
ln -s "$T/managed" "$T/target/themes/managed"
# A new symlink is not accepted even when it presents identical copied bytes.
cp "$T/target/uploads/image.png" "$T/other/image.png"
rm "$T/target/uploads/image.png"
ln -s "$T/other/image.png" "$T/target/uploads/image.png"
refuse run verify
rm "$T/target/uploads/image.png"
cp "$T/source/uploads/image.png" "$T/target/uploads/image.png"
printf unexpected > "$T/source/uploads/new.png"
refuse run verify
rm "$T/source/uploads/new.png"
refuse php "$helper" verify "$policy" "$T/source" "$T/target" "$(printf changed | sha256sum | awk '{print $1}')"
mv "$policy" "$T/saved.json"
refuse run verify
ln -s "$T/saved.json" "$policy"
refuse run verify
rm "$policy"
mv "$T/saved.json" "$policy"
run verify > /dev/null
# A forged exclusion for ordinary content is rejected.
cp "$policy" "$T/saved.json"
php -r '$p=json_decode(file_get_contents($argv[1]),true);$p["entries"]["uploads/image.png"][0]="excluded";file_put_contents($argv[1],json_encode($p));' "$policy"
refuse run verify
mv "$T/saved.json" "$policy"
# Nested destination links deliberately excluded by rsync are also recorded.
rm "$policy"
mkdir -p "$T/source/plugins/sample/assets" "$T/nested"
printf original > "$T/source/plugins/sample/assets/file.css"
printf managed > "$T/nested/file.css"
ln -s "$T/nested" "$T/target/plugins/sample/assets"
mkdir -p "$T/source/plugins/redis-cache"
printf excluded > "$T/source/plugins/redis-cache/plugin.php"
run capture
run verify > "$T/pass.txt"
grep -Fxq 'preserved_paths_count=2' "$T/pass.txt"
# Disallow ambiguous nested symlinks within the preserved platform tree.
rm "$policy"
ln -s "$T/other/style.css" "$T/managed/nested-link.css"
refuse run capture
printf 'archive file policy smoke test passed\n'

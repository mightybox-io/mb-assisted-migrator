#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/mb-archive-relay-test.XXXXXX")"
# shellcheck disable=SC2154 # status is assigned inside this EXIT trap.
trap 'status=$?; if [[ "$status" -ne 0 ]]; then find "$T" -maxdepth 1 -name "*.log" -type f -exec sh -c '\''cat "$1" >&2'\'' sh {} \;; fi; rm -rf "$T"' EXIT
export ARCHIVE_RELAY_TEST_ROOT="$T"
mkdir -p "$T/target/wp-content" "$T/bin" "$T/home" "$T/state"
printf '<?php\n' > "$T/target/wp-config.php"
printf 'destination-key\n' > "$T/destination-key"
printf 'destination-known-hosts\n' > "$T/destination-known-hosts"
php -r '
  $zip = new ZipArchive(); $zip->open($argv[1], ZipArchive::CREATE);
  foreach ([
    "wp-content/mysql.sql" => "CREATE TABLE `wp_posts` (`ID` bigint, `post_type` text, `post_status` text, `post_name` text, `post_title` text, `post_content` text, `post_excerpt` text, `post_parent` bigint, `menu_order` int);\nINSERT INTO `wp_posts` VALUES (1,".chr(39)."post".chr(39).",".chr(39)."publish".chr(39).",".chr(39)."evidence".chr(39).",".chr(39)."Title".chr(39).",".chr(39)."Body".chr(39).",".chr(39).chr(39).",0,0);\n",
    "wp-content/plugins/sample/plugin.php" => "plugin",
    "wp-content/themes/sample/style.css" => "theme",
    "wp-content/themes/managed/style.css" => "source-theme",
    "wp-content/uploads/evidence.txt" => "archive-evidence",
    "wp-content/mu-plugins/wpengine-common/loader.php" => "excluded",
    "wp-content/object-cache.php" => "excluded"
  ] as $path => $body) $zip->addFromString($path, $body);
  $zip->close();
' "$T/backup.zip"

cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$ARCHIVE_RELAY_TEST_ROOT/wp-calls"
case "$*" in
  *'core is-installed'*) exit 0 ;;
  *'post list '*--format=json*)
    if [[ -f "$ARCHIVE_RELAY_TEST_ROOT/corrupt-content" ]]; then echo '[]'; else
      echo '[{"ID":1,"post_type":"post","post_status":"publish","post_name":"evidence","post_title":"Title","post_content":"Body","post_excerpt":"","post_parent":0,"menu_order":0}]'
    fi ;;
  *'post list '*--format=count*) echo 2 ;;
  *'user list --role=administrator --format=count'*) echo 1 ;;
  *'user list --format=count'*) echo 1 ;;
  *'option get home'*|*'option get siteurl'*) echo https://destination.example.test ;;
  *'db query SELECT 1'*) echo 1 ;;
  *'db export '*) while [[ "$1" != export ]]; do shift; done; printf 'CREATE TABLE old_table (`id` int);\n' > "$2" ;;
  *'db import '*) exit 0 ;;
  *'search-replace '*--format=count*) echo 0 ;;
  *'search-replace '*) exit 0 ;;
  *'cache flush'*) exit 0 ;;
  *eval*) exit 0 ;;
  *) exit 80 ;;
esac
WP
cat > "$T/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -eu
while [[ "${1:-}" == -* ]]; do shift 2; done
printf called >> "$ARCHIVE_RELAY_TEST_ROOT/ssh-calls"
host="$1"; shift
[[ "$host" == dest@test ]] || exit 91
export HOME="$ARCHIVE_RELAY_TEST_ROOT/home"
if [[ "${1:-}" == bash && "${2:-}" == -s ]]; then exec "$@"; fi
if [[ "$*" == 'bash -lc '* ]]; then eval "set -- $*"; exec bash -c "$3"; fi
exec bash -c "$*"
SSH
REAL_RSYNC="$(command -v rsync)"
cat > "$T/bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -eu
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e) shift 2; continue ;;
    dest@test:*) args+=("${1#*:}") ;;
    *) args+=("$1") ;;
  esac
  shift
done
exec "$ARCHIVE_RELAY_REAL_RSYNC" "${args[@]}"
RSYNC
cat > "$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
printf 200
CURL
chmod +x "$T/bin/"*
export ARCHIVE_RELAY_REAL_RSYNC="$REAL_RSYNC"
export PATH="$T/bin:$PATH"
sha="$(sha256sum "$T/backup.zip" | awk '{print $1}')"
cp "$T/backup.zip" "$T/unknown.zip"
php -r '$z=new ZipArchive();$z->open($argv[1]);$z->addFromString("wp-content/mu-plugins/customer.php","custom");$z->close();' "$T/unknown.zip"
unknown_sha="$(sha256sum "$T/unknown.zip" | cut -d' ' -f1)"
if "$ROOT_DIR/bin/mb-migrator" archive-relay "$T/unknown.zip" --provider=wpengine \
  --destination=dest@test --target-root="$T/target" --archive-sha256="$unknown_sha" \
  --old-url=https://source.example.test --new-url=https://destination.example.test \
  --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" \
  --state-dir="$T/state" > "$T/unknown.log" 2>&1; then
  echo 'Unknown component reached restore' >&2; exit 1
fi
test ! -e "$T/ssh-calls"
grep -q 'Archive normalization requires review' "$T/unknown.log"
# A category-root symlink must fail before copy, rollback or database mutation.
for category in plugins themes uploads; do
  fixture="$T/category-$category"
  mkdir -p "$fixture/target/wp-content" "$fixture/managed/sample"
  printf '<?php\n' > "$fixture/target/wp-config.php"
  printf provider-original > "$fixture/managed/sample/plugin.php"
  ln -s "$fixture/managed" "$fixture/target/wp-content/$category"
  : > "$T/wp-calls"
  if MB_MIGRATOR_ARCHIVE_POLICY="$fixture/policy.json" MB_MIGRATOR_ARCHIVE_SHA256="$sha" \
    "$ROOT_DIR/bin/mb-migrator" restore "$T/backup.zip" --provider=wpengine \
      --target-root="$fixture/target" --stage-dir="$fixture/stage" --rollback-dir="$fixture/rollback" \
      --old-url=https://source.example.test --new-url=https://destination.example.test \
      --search-replace --db-import=yes --mu-plugins=skip --root-extras=skip \
      --cleanup=no --safety=enable --yes > "$T/category-$category.log" 2>&1; then
    echo "Category-root symlink unexpectedly accepted: $category" >&2; exit 1
  fi
  grep -q 'Archive file policy validation failed' "$T/category-$category.log"
  test ! -e "$fixture/policy.json"
  test ! -e "$fixture/rollback"
  test ! -e "$fixture/target/wp-content/mu-plugins/mb-migrator-safety.php"
  test -L "$fixture/target/wp-content/$category"
  [[ "$(cat "$fixture/managed/sample/plugin.php")" == provider-original ]]
  [[ "$(find "$fixture/managed" -type f | wc -l)" -eq 1 ]]
  if grep -Eq 'db (export|import)|search-replace' "$T/wp-calls"; then
    echo 'Database operation ran before layout rejection' >&2; exit 1
  fi
done
run_archive_relay() {
  "$ROOT_DIR/bin/mb-migrator" archive-relay "$T/backup.zip" --provider=wpengine \
    --destination=dest@test --target-root="$T/target" --archive-sha256="$sha" \
    --old-url=https://source.example.test --new-url=https://destination.example.test \
    --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" \
    --state-dir="$T/state"
}
mkdir -p "$T/platform-theme" "$T/target/wp-content/themes"
printf platform-theme > "$T/platform-theme/style.css"
ln -s "$T/platform-theme" "$T/target/wp-content/themes/managed"
run_archive_relay > "$T/restore.log"
test -L "$T/target/wp-content/themes/managed"
[[ "$(cat "$T/platform-theme/style.css")" == platform-theme ]]
[[ "$(cat "$T/target/wp-content/uploads/evidence.txt")" == archive-evidence ]]
test -f "$T/target/wp-content/plugins/sample/plugin.php"
test -f "$T/target/wp-content/themes/sample/style.css"
test ! -e "$T/target/wp-content/mu-plugins/wpengine-common/loader.php"
test ! -e "$T/target/wp-content/object-cache.php"
test -f "$T/target/wp-content/mu-plugins/mb-migrator-safety.php"
verify_output="$("$ROOT_DIR/bin/mb-migrator" archive-verify --destination=dest@test \
  --target-root="$T/target" --archive-sha256="$sha" \
  --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
  --expected-url=https://destination.example.test \
  --expected-safety=enabled \
  --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" --json)"
php -r 'json_decode($argv[1], true, 512, JSON_THROW_ON_ERROR);' "$verify_output"
grep -q '"verification_basis":"immutable_provider_archive"' <<< "$verify_output"
grep -q '"status":"verified"' <<< "$verify_output"
grep -q '"archive":true' <<< "$verify_output"
grep -q '"files":true' <<< "$verify_output"
grep -q '"rollback":true' <<< "$verify_output"
grep -q '"content":true' <<< "$verify_output"
grep -q '"normalization":true' <<< "$verify_output"
touch "$T/corrupt-content"
if "$ROOT_DIR/bin/mb-migrator" archive-verify --destination=dest@test \
  --target-root="$T/target" --archive-sha256="$sha" \
  --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 --expected-url=https://destination.example.test \
  --expected-safety=enabled --destination-identity="$T/destination-key" \
  --destination-known-hosts="$T/destination-known-hosts" --json > "$T/content-failure.json"; then
  echo 'Missing restored posts unexpectedly verified' >&2; exit 1
fi
grep -q '"content":false' "$T/content-failure.json"
rm "$T/corrupt-content"
# Verification must consume the original pre-copy record, never rebaseline.
relay_id="$(printf '%s' "$sha|dest@test|22|$T/target" | sha256sum | cut -c1-20)"
policy="$T/home/.local/state/mb-migrator/archive-relay/$relay_id/archive-file-policy.json"
assert_policy_failure() {
  if "$ROOT_DIR/bin/mb-migrator" archive-verify --destination=dest@test \
    --target-root="$T/target" --archive-sha256="$sha" \
    --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
    --expected-url=https://destination.example.test --expected-safety=enabled \
    --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" --json > "$T/policy-failure.json"; then
    echo 'Invalid preservation policy unexpectedly verified' >&2; exit 1
  fi
  grep -q '"files":false' "$T/policy-failure.json"
}
mv "$policy" "$policy.saved"
assert_policy_failure
test ! -e "$policy"
mv "$policy.saved" "$policy"
printf changed-platform-theme > "$T/platform-theme/style.css"
assert_policy_failure
printf platform-theme > "$T/platform-theme/style.css"
"$ROOT_DIR/bin/mb-migrator" safety disable --target-root="$T/target" --live-url=https://destination.example.test --yes > "$T/release.log"
released_output="$("$ROOT_DIR/bin/mb-migrator" archive-verify --destination=dest@test \
  --target-root="$T/target" --archive-sha256="$sha" \
  --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
  --expected-url=https://destination.example.test --expected-safety=disabled \
  --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" --json)"
grep -q '"status":"verified"' <<< "$released_output"
grep -q '"safety_state":"disabled"' <<< "$released_output"
printf corrupt > "$T/target/wp-content/uploads/evidence.txt"
if "$ROOT_DIR/bin/mb-migrator" archive-verify --destination=dest@test \
  --target-root="$T/target" --archive-sha256="$sha" \
  --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
  --expected-url=https://destination.example.test \
  --expected-safety=enabled \
  --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" --json > "$T/corrupt.json"; then
  echo 'Corrupt destination file unexpectedly verified' >&2; exit 1
fi
grep -q '"status":"failed"' "$T/corrupt.json"
grep -q '"files":false' "$T/corrupt.json"
printf 'archive relay smoke test passed\n'

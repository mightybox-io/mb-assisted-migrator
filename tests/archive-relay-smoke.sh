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
    "wp-content/mysql.sql" => "CREATE TABLE `wp_options` (`id` bigint);\n",
    "wp-content/plugins/sample/plugin.php" => "plugin",
    "wp-content/themes/sample/style.css" => "theme",
    "wp-content/uploads/evidence.txt" => "archive-evidence",
    "wp-content/mu-plugins/wpengine-common/loader.php" => "excluded",
    "wp-content/object-cache.php" => "excluded"
  ] as $path => $body) $zip->addFromString($path, $body);
  $zip->close();
' "$T/backup.zip"

cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
set -eu
case "$*" in
  *'core is-installed'*) exit 0 ;;
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
  *) exit 80 ;;
esac
WP
cat > "$T/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -eu
while [[ "${1:-}" == -* ]]; do shift 2; done
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
run_archive_relay() {
  "$ROOT_DIR/bin/mb-migrator" archive-relay "$T/backup.zip" --provider=wpengine \
    --destination=dest@test --target-root="$T/target" --archive-sha256="$sha" \
    --old-url=https://source.example.test --new-url=https://destination.example.test \
    --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" \
    --state-dir="$T/state"
}
run_archive_relay > "$T/restore.log"
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
  --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" --json)"
php -r 'json_decode($argv[1], true, 512, JSON_THROW_ON_ERROR);' "$verify_output"
grep -q '"verification_basis":"immutable_provider_archive"' <<< "$verify_output"
grep -q '"status":"verified"' <<< "$verify_output"
grep -q '"archive":true' <<< "$verify_output"
grep -q '"files":true' <<< "$verify_output"
grep -q '"rollback":true' <<< "$verify_output"
printf corrupt > "$T/target/wp-content/uploads/evidence.txt"
if "$ROOT_DIR/bin/mb-migrator" archive-verify --destination=dest@test \
  --target-root="$T/target" --archive-sha256="$sha" \
  --run-id=019a4dc8-d9ff-73f2-8e98-2e6905994c10 \
  --expected-url=https://destination.example.test \
  --destination-identity="$T/destination-key" --destination-known-hosts="$T/destination-known-hosts" --json > "$T/corrupt.json"; then
  echo 'Corrupt destination file unexpectedly verified' >&2; exit 1
fi
grep -q '"status":"failed"' "$T/corrupt.json"
grep -q '"files":false' "$T/corrupt.json"
printf 'archive relay smoke test passed\n'

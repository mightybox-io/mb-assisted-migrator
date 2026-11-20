#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/mb-evidence-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
php "$ROOT_DIR/tests/archive-evidence-fixture.php" "$T"
sha="$(sha256sum "$T/backup.zip" | cut -d' ' -f1)"
php "$ROOT_DIR/lib/archive-content.php" inspect "$T/backup.zip" "$sha" https://source.test https://destination.test > "$T/expected"
php "$ROOT_DIR/lib/archive-content.php" verify "$T/backup.zip" "$sha" https://source.test https://destination.test < "$T/actual.json" > "$T/actual"
cmp "$T/expected" "$T/actual"
for file in corrupt empty; do
  if php "$ROOT_DIR/lib/archive-content.php" verify "$T/backup.zip" "$sha" https://source.test https://destination.test < "$T/$file.json"; then echo 'Bad content accepted' >&2; exit 1; fi
done
php "$ROOT_DIR/lib/archive-normalization.php" "$T/backup.zip" "$sha" | grep -q wpengine.mu.wpengine-common-v1
for name in unknown lookalike dropin; do
  bad_sha="$(sha256sum "$T/$name.zip" | cut -d' ' -f1)"
  if php "$ROOT_DIR/lib/archive-normalization.php" "$T/$name.zip" "$bad_sha"; then echo 'Unknown component accepted' >&2; exit 1; fi
done
for name in duplicate unquoted columns truncated mode ambiguous oversized; do
  bad_sha="$(sha256sum "$T/$name.zip" | cut -d' ' -f1)"
  if php "$ROOT_DIR/lib/archive-content.php" inspect "$T/$name.zip" "$bad_sha" https://source.test https://destination.test; then echo 'Unsupported SQL accepted' >&2; exit 1; fi
done
if php "$ROOT_DIR/lib/archive-content.php" inspect "$T/backup.zip" "$(printf '0%.0s' {1..64})" https://source.test https://destination.test; then echo 'Wrong archive binding accepted' >&2; exit 1; fi
printf 'Archive content and normalization evidence passed\n'

reviewed_sha="$(sha256sum "$T/reviewed.zip" | cut -d' ' -f1)"
php "$ROOT_DIR/lib/archive-normalization.php" "$T/reviewed.zip" "$reviewed_sha" > "$T/reviewed.json"
php -r '$r=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR); $ids=array_column($r["rules"],"rule_id"); if ($ids !== ["wpengine.mu.cache-plugin-v1","wpengine.mu.seamless-login-v1","wpengine.mu.security-auditor-v1","wpengine.mu.wpengine-common-v1"] || $r["unknown_components_count"] !== 0 || array_unique(array_column($r["rules"],"outcome")) !== ["excluded_from_source"]) { exit(1); }' "$T/reviewed.json"
for archive in "$T"/blocked-*.zip; do
  blocked_sha="$(sha256sum "$archive" | cut -d' ' -f1)"
  if php "$ROOT_DIR/lib/archive-normalization.php" "$archive" "$blocked_sha"; then echo 'Unreviewed sibling or update selector accepted' >&2; exit 1; fi
done
printf 'Exact provider family exclusions passed\n'

#!/usr/bin/env bash
set -euo pipefail

state_root="${1:-}"; target_root="${2:-}"; expected_sha="${3:-}"; expected_url="${4:-}"; expected_safety="${5:-}"; rollback_dir="${6:-}"; safety_sha="${7:-}"
fail() { printf '[archive-verification:error] %s\n' "$*" >&2; exit 1; }
[[ "$state_root" =~ ^/[A-Za-z0-9._/-]+$ && -d "$state_root" && ! -L "$state_root" ]] || fail "invalid retained state"
[[ "$target_root" =~ ^/[A-Za-z0-9._/-]+$ && -d "$target_root/wp-content" ]] || fail "invalid target root"
[[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || fail "invalid archive digest"
[[ "$expected_url" =~ ^https?://[^[:space:]]+$ ]] || fail "invalid expected URL"
case "$expected_safety" in enabled|disabled) ;; *) fail "invalid expected safety state" ;; esac
command -v wp >/dev/null 2>&1 || fail "WP-CLI unavailable"
command -v find >/dev/null 2>&1 || fail "find unavailable"
if command -v sha256sum >/dev/null 2>&1; then hash_file() { sha256sum "$1" | awk '{print $1}'; }; else hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }; fi

archive=no; files=no; wordpress=no; urls=no; administrator=no; serialized_urls=no; safety=no; rollback=no
[[ -f "$state_root/archive/backup.zip" && ! -L "$state_root/archive/backup.zip" && "$(hash_file "$state_root/archive/backup.zip")" == "$expected_sha" ]] && archive=yes
[[ -f "$state_root/archive-manifest" && ! -L "$state_root/archive-manifest" ]] || fail "archive manifest unavailable"
old_url="$(awk -F= '$1 == "old_url" {sub(/^[^=]*=/, ""); print; exit}' "$state_root/archive-manifest")"
manifest_sha="$(awk -F= '$1 == "archive_sha256" {print $2; exit}' "$state_root/archive-manifest")"
[[ "$manifest_sha" == "$expected_sha" && "$old_url" =~ ^https?://[^[:space:]]+$ ]] || fail "archive manifest invalid"
stage_content="$state_root/stage/htdocs/wp-content"
[[ -d "$stage_content" && ! -L "$stage_content" ]] || fail "retained extracted content unavailable"
migrated_files_count=0; media_count=0
# Policy is captured before copying, never synthesized by verification. Legacy
# retained runs without this evidence require explicit operator reconciliation.
if policy_output="$(php "$state_root/runner/lib/archive-file-policy.php" verify \
    "$state_root/archive-file-policy.json" "$stage_content" "$target_root/wp-content" "$expected_sha" 2>/dev/null)"; then
  files=yes
  migrated_files_count="$(printf '%s\n' "$policy_output" | awk -F= '$1 == "migrated_files_count" {print $2}')"
  media_count="$(printf '%s\n' "$policy_output" | awk -F= '$1 == "media_count" {print $2}')"
fi

wp_site() (cd "$target_root" && wp --skip-plugins --skip-themes "$@");
if wp_site core is-installed >/dev/null 2>&1; then wordpress=yes; fi
home="$(wp_site option get home 2>/dev/null || true)"; siteurl="$(wp_site option get siteurl 2>/dev/null || true)"
[[ "${home%/}" == "${expected_url%/}" && "${siteurl%/}" == "${expected_url%/}" ]] && urls=yes
admin_count="$(wp_site user list --role=administrator --format=count 2>/dev/null || true)"; [[ "$admin_count" =~ ^[0-9]+$ && "$admin_count" -gt 0 ]] && administrator=yes
old_matches="$(wp_site search-replace "$old_url" "$expected_url" --all-tables-with-prefix --skip-columns=guid --dry-run --precise --format=count 2>/dev/null || true)"; [[ "$old_matches" == 0 ]] && serialized_urls=yes
content=no; content_count=0; content_sha256=""
content_file="$(mktemp "$state_root/content-check.XXXXXX")"
trap 'rm -f "$content_file"' EXIT
if (ulimit -f 65536; wp_site post list --post_type=post,page --post_status=publish,future,draft,pending,private,trash,auto-draft,inherit \
    --fields=ID,post_type,post_status,post_name,post_title,post_content,post_excerpt,post_parent,menu_order \
    --orderby=ID --order=ASC --posts_per_page=-1 --format=json) > "$content_file" 2>/dev/null \
    && content_output="$(php "$state_root/runner/lib/archive-content.php" verify "$state_root/archive/backup.zip" "$expected_sha" "$old_url" "$expected_url" < "$content_file" 2>/dev/null)"; then
  content=yes
  content_count="$(printf '%s\n' "$content_output" | awk -F= '$1 == "content_count" {print $2}')"
  content_sha256="$(printf '%s\n' "$content_output" | awk -F= '$1 == "content_sha256" {print $2}')"
fi
normalization=no; normalization_json=null
if normalization_json="$(php "$state_root/runner/lib/archive-normalization.php" "$state_root/archive/backup.zip" "$expected_sha" 2>/dev/null)"; then normalization=yes; fi

guard="$target_root/wp-content/mu-plugins/mb-migrator-safety.php"
if [[ "$expected_safety" == enabled ]]; then
  [[ -f "$guard" && ! -L "$guard" && "$(hash_file "$guard")" == "$safety_sha" ]] && safety=yes
else
  [[ ! -e "$guard" && ! -L "$guard" ]] && safety=yes
fi
if [[ "$rollback_dir" =~ ^/[A-Za-z0-9._/-]+$ && -d "$rollback_dir" && ! -L "$rollback_dir" && -f "$rollback_dir/target-root" && ! -L "$rollback_dir/target-root" && "$(<"$rollback_dir/target-root")" == "$(cd "$target_root" && pwd -P)" && -f "$rollback_dir/added-files" && ! -L "$rollback_dir/added-files" && ! -e "$rollback_dir/restored" ]]; then rollback=yes; fi
printf 'archive=%s\nfiles=%s\nwordpress=%s\nurls=%s\nadministrator=%s\nserialized_urls=%s\nsafety=%s\nrollback=%s\n' "$archive" "$files" "$wordpress" "$urls" "$administrator" "$serialized_urls" "$safety" "$rollback"
printf 'migrated_files_count=%s\ncontent_count=%s\nmedia_count=%s\n' "$migrated_files_count" "$content_count" "$media_count"
printf 'administrator_count=%s\n' "${admin_count:-0}"

printf 'content=%s\ncontent_sha256=%s\nnormalization=%s\nnormalization_json=%s\n' "$content" "$content_sha256" "$normalization" "${normalization_json:-null}"

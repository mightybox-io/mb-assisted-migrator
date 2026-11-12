#!/usr/bin/env bash

normalization_profile_validate() {
  case "$1" in
    none|wp-engine-v1) return 0 ;;
  esac
  return 1
}

normalization_profile_rules() {
  case "$1" in
    none) return 0 ;;
    wp-engine-v1)
      cat <<'EOF'
wpengine.mu.wpengine-common-v1|mu-plugins/wpengine-common
wpengine.mu.force-strong-passwords-v1|mu-plugins/force-strong-passwords
wpengine.mu.loader-v1|mu-plugins/mu-plugin.php
wpengine.mu.slt-force-strong-passwords-v1|mu-plugins/slt-force-strong-passwords.php
wpengine.mu.stop-long-comments-v1|mu-plugins/stop-long-comments.php
EOF
      ;;
    *) return 1 ;;
  esac
}

normalization_profile_remote_args() {
  local profile="$1" rule_id relative_path
  printf '%s\n' "$profile"
  while IFS='|' read -r rule_id relative_path; do
    [[ -n "$rule_id" ]] || continue
    printf '%s|%s\n' "$rule_id" "$relative_path"
  done < <(normalization_profile_rules "$profile")
}

normalization_profile_rsync_excludes() {
  local profile="$1" rule_id relative_path
  while IFS='|' read -r rule_id relative_path; do
    [[ -n "$rule_id" ]] || continue
    printf '/%s\n/%s/***\n' "$relative_path" "$relative_path"
  done < <(normalization_profile_rules "$profile")
}

normalization_profile_has_rule() {
  local profile="$1" expected="$2" rule_id relative_path
  while IFS='|' read -r rule_id relative_path; do
    [[ "$rule_id" == "$expected" ]] && return 0
  done < <(normalization_profile_rules "$profile")
  return 1
}

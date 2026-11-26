#!/usr/bin/env bash

wpcli_import_db() {
  local target_root="$1"
  local sql_file="$2"
  local skip_backup="$3"
  local delete_sql_after_import="$4"

  [[ -f "$sql_file" ]] || die "SQL file not found: $sql_file"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log "Would import database from $target_root: wp db import $sql_file"
    return 0
  fi

  local method="${TARGET_DB_METHOD:-auto}"
  local backup="" wp_available=0
  command -v wp >/dev/null 2>&1 && wp_available=1
  if [[ "$method" == "wp-cli" && "$wp_available" -eq 0 ]]; then die "WP-CLI target DB method requested but wp is unavailable"; fi

  if [[ "$skip_backup" -ne 1 ]]; then
    if [[ -n "${ROLLBACK_DIR:-}" ]]; then
      backup="$ROLLBACK_DIR/database-before.sql"
    else
      backup="$(mktemp "${TMPDIR:-/tmp}/mb-migrator-db-backup.XXXXXX")"
    fi
    log "Backing up current database to $backup"
    if [[ "$method" != "native" && "$wp_available" -eq 1 ]] && wp_in_root "$target_root" --skip-plugins --skip-themes db export "$backup"; then
      chmod 600 "$backup"
    elif [[ "$method" == "wp-cli" ]]; then
      die "WP-CLI target database backup failed"
    else
      warn "Using native target database backup"
      native_db_backup "$target_root" "$backup"
    fi
    report "Database backup before import: $backup"
  fi

  log "Importing database"
  if [[ "$method" != "native" && "$wp_available" -eq 1 ]] && wp_in_root "$target_root" --skip-plugins --skip-themes db import "$sql_file"; then
    report "Target database method: wp-cli"
  elif [[ "$method" == "wp-cli" ]]; then
    die "WP-CLI target database import failed"
  else
    warn "Using native target database import"
    native_db_import "$target_root" "$sql_file"
    report "Target database method: native"
  fi
  report "Imported database from $sql_file"
  DB_IMPORT_RAN=1

  if [[ "$delete_sql_after_import" -eq 1 ]]; then
    log "Deleting combined SQL after successful import: $sql_file"
    rm -f "$sql_file"
    report "Deleted combined SQL after successful import: $sql_file"
  fi
}

wpcli_maybe_import_db() {
  local target_root="$1"
  local sql_file="$2"
  local skip_backup="$3"
  local import_mode="$4"
  local delete_sql_after_import="$5"

  case "$import_mode" in
    yes)
      wpcli_import_db "$target_root" "$sql_file" "$skip_backup" "$delete_sql_after_import"
      ;;
    no)
      log "Skipping database import"
      report "Database import: skipped"
      ;;
    ask)
      if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "Would ask whether to import the combined SQL into the target database; default answer is yes"
        log "Would import database from $target_root: wp db import $sql_file"
        if [[ "$delete_sql_after_import" -eq 1 ]]; then
          log "Would delete combined SQL after successful import: $sql_file"
        fi
        report "Database import: ask deferred by dry-run, default yes"
      elif confirm_default_yes "Import combined SQL into the database configured by $target_root/wp-config.php?"; then
        wpcli_import_db "$target_root" "$sql_file" "$skip_backup" "$delete_sql_after_import"
      else
        log "Skipping database import"
        report "Database import: skipped by user"
      fi
      ;;
    *)
      die "Invalid database import mode: $import_mode"
      ;;
  esac
}

wpcli_search_replace() {
  local target_root="$1"
  local old_url="$2"
  local new_url="$3"
  local permalink_structure=""
  local prefix=""
  local skip_columns="guid"
  local -a exclusions=()

  # The archive path must never rewrite WordPress identities or profile data.
  # Source and destination must be full URLs, so email domains are not search
  # terms; skipping these tables is a second independent boundary.
  if [[ -n "${MB_MIGRATOR_ARCHIVE_POLICY:-}" ]]; then
    [[ "$old_url" =~ ^https?://[^[:space:]]+$ && "$new_url" =~ ^https?://[^[:space:]]+$ ]] || die "Archive URL replacement requires full HTTP(S) URLs"
    prefix="$(wp_in_root "$target_root" --skip-plugins --skip-themes db prefix)" || die "Archive database prefix is unavailable"
    [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || die "Archive database prefix is invalid"
    exclusions+=("--skip-tables=${prefix}users,${prefix}usermeta")
    skip_columns="guid,user_email,user_login,user_nicename"
  fi

  if ! command -v wp >/dev/null 2>&1; then
    warn "WP-CLI is unavailable; URL rewrite is pending"
    warn "Run later: cd '$target_root' && wp search-replace '$old_url' '$new_url' --all-tables-with-prefix --precise --recurse-objects --skip-columns=guid"
    report "URL rewrite pending: WP-CLI unavailable"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    wp_in_root "$target_root" --skip-plugins --skip-themes search-replace "$old_url" "$new_url" --all-tables-with-prefix --precise --recurse-objects "--skip-columns=$skip_columns" "${exclusions[@]}" --dry-run
    return 0
  fi

  confirm "Run serialized-safe search-replace from $old_url to $new_url?" || die "Search-replace cancelled"
  if ! wp_in_root "$target_root" --skip-plugins --skip-themes search-replace "$old_url" "$new_url" --all-tables-with-prefix --precise --recurse-objects "--skip-columns=$skip_columns" "${exclusions[@]}"; then
    warn "WP-CLI search-replace failed; URL rewrite is pending"
    report "URL rewrite pending: WP-CLI command failed"
    return 0
  fi
  report "Ran search-replace from $old_url to $new_url"
  permalink_structure="$(wp_in_root "$target_root" --skip-plugins --skip-themes option get permalink_structure)" || die "Cannot verify destination permalink configuration"
  if [[ -n "$permalink_structure" ]]; then
    wp_in_root "$target_root" --skip-plugins --skip-themes rewrite flush || die "Destination permalink rule refresh failed"
    report "Pretty permalink rules refreshed without changing their structure"
  else
    report "Plain permalink mode preserved; rewrite flush not required"
  fi
  if wp_in_root "$target_root" --skip-plugins --skip-themes cache flush; then
    log "Flushed the WordPress object cache after URL replacement"
    report "WordPress object cache flushed"
  else
    warn "URL replacement succeeded, but the WordPress object cache could not be flushed"
    report "WordPress object cache flush: failed"
  fi
}

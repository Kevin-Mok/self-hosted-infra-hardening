#!/usr/bin/env bash
set -euo pipefail

script_name=$(basename "$0")

usage() {
  cat <<EOF
Usage: sudo $script_name [output-dir]

Collect a focused Gitea state audit into a timestamped directory.
If output-dir is omitted, the script writes to /tmp/gitea-state-audit-<UTC timestamp>.

The audit includes:
- selected service and server settings from /etc/gitea/app.ini
- recent users and repositories from the SQLite database
- repository counts by owner
- basic database file metadata
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if (( $# > 1 )); then
  usage >&2
  exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'This script must be run with sudo or as root.\n' >&2
  printf 'Example: sudo %s\n' "$script_name" >&2
  exit 1
fi

app_ini=/etc/gitea/app.ini
db_path=/var/lib/gitea/data/gitea.db
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir=${1:-/tmp/gitea-state-audit-$timestamp}
install -d -m 0755 "$output_dir"

log() {
  printf '%s\n' "$*" >&2
}

run_capture() {
  local filename=$1
  shift

  log "Capturing $filename"
  if "$@" >"$output_dir/$filename" 2>&1; then
    return 0
  fi

  local status=$?
  {
    printf '\ncommand:'
    printf ' %q' "$@"
    printf '\nexit_status: %s\n' "$status"
  } >>"$output_dir/$filename"
}

capture_summary() {
  log "Capturing summary.txt"
  {
    printf 'captured_at_utc=%s\n' "$(date -u '+%F %T UTC')"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'output_dir=%s\n' "$output_dir"
    printf 'app_ini=%s\n' "$app_ini"
    printf 'db_path=%s\n' "$db_path"
    printf 'sqlite3_present=%s\n' "$(command -v sqlite3 >/dev/null 2>&1 && echo yes || echo no)"
  } >"$output_dir/summary.txt"
}

capture_safe_config() {
  local output_file=$output_dir/gitea-config-audit.txt

  log "Capturing $(basename "$output_file")"

  if [[ ! -r $app_ini ]]; then
    printf '%s is not readable on this host.\n' "$app_ini" >"$output_file"
    return 0
  fi

  awk '
    BEGIN {
      print "# Safe subset of /etc/gitea/app.ini"
      print "# Secret-bearing keys are intentionally omitted."
      print ""
    }
    /^\[/ {
      section = tolower($0)
      keep = (section == "[database]" || section == "[server]" || section == "[service]")
      if (keep) {
        print $0
      }
      next
    }
    /^[[:space:]]*($|;|#)/ { next }
    section == "[database]" && $1 ~ /^(DB_TYPE|HOST|NAME|USER|SCHEMA|SSL_MODE|PATH)$/ { print; next }
    section == "[server]" && $1 ~ /^(DOMAIN|ROOT_URL|HTTP_PORT|PROTOCOL|SSH_DOMAIN|SSH_PORT)$/ { print; next }
    section == "[service]" && $1 ~ /^(DISABLE_REGISTRATION|ALLOW_ONLY_EXTERNAL_REGISTRATION|SHOW_REGISTRATION_BUTTON|REGISTER_EMAIL_CONFIRM|DEFAULT_KEEP_EMAIL_PRIVATE|DEFAULT_ALLOW_CREATE_ORGANIZATION)$/ { print; next }
  ' "$app_ini" >"$output_file"
}

capture_db_file_metadata() {
  local output_file=$output_dir/sqlite-db-metadata.txt

  log "Capturing $(basename "$output_file")"
  if [[ ! -e $db_path ]]; then
    printf '%s does not exist on this host.\n' "$db_path" >"$output_file"
    return 0
  fi

  {
    stat "$db_path"
    printf '\n'
    du -h "$db_path"
  } >"$output_file" 2>&1
}

run_sql() {
  local filename=$1
  local sql=$2

  if ! command -v sqlite3 >/dev/null 2>&1; then
    log "Capturing $filename"
    printf 'sqlite3 is not installed on this host.\n' >"$output_dir/$filename"
    return 0
  fi

  if [[ ! -r $db_path ]]; then
    log "Capturing $filename"
    printf '%s is not readable on this host.\n' "$db_path" >"$output_dir/$filename"
    return 0
  fi

  run_capture "$filename" sqlite3 -header -column "$db_path" "$sql"
}

capture_sql_audits() {
  run_sql recent-users.txt "
    SELECT
      id,
      name,
      lower_name,
      is_admin,
      is_active,
      is_restricted,
      visibility,
      datetime(created_unix, 'unixepoch') AS created_utc,
      last_login_unix
    FROM user
    ORDER BY id DESC
    LIMIT 30;
  "

  run_sql recent-repositories.txt "
    SELECT
      r.id,
      u.name AS owner,
      r.lower_name,
      r.is_private,
      r.is_fork,
      r.is_mirror,
      datetime(r.created_unix, 'unixepoch') AS created_utc
    FROM repository r
    JOIN user u ON u.id = r.owner_id
    ORDER BY r.id DESC
    LIMIT 40;
  "

  run_sql repository-counts-by-owner.txt "
    SELECT
      u.name AS owner,
      COUNT(*) AS repo_count
    FROM repository r
    JOIN user u ON u.id = r.owner_id
    GROUP BY u.id, u.name
    ORDER BY repo_count DESC, owner ASC;
  "

  run_sql totals.txt "
    SELECT 'users_total' AS metric, COUNT(*) AS value FROM user
    UNION ALL
    SELECT 'repos_total', COUNT(*) FROM repository
    UNION ALL
    SELECT 'public_repos_total', COUNT(*) FROM repository WHERE is_private = 0
    UNION ALL
    SELECT 'private_repos_total', COUNT(*) FROM repository WHERE is_private = 1
    UNION ALL
    SELECT 'organizations_total', COUNT(*) FROM user WHERE type = 1;
  "
}

capture_summary
capture_safe_config
capture_db_file_metadata
capture_sql_audits

log "Capturing manifest.txt"
find "$output_dir" -maxdepth 1 -type f -printf '%f\n' | sort >"$output_dir/manifest.txt"

printf 'Gitea state audit written to %s\n' "$output_dir"

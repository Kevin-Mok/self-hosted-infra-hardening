#!/usr/bin/env bash
set -euo pipefail

script_name=$(basename "$0")

usage() {
  cat <<EOF
Usage: sudo $script_name [output-dir]

Collect privileged Gitea and Nginx diagnostics into a timestamped directory.
If output-dir is omitted, the script writes to /tmp/gitea-incident-<UTC timestamp>.

The capture bundle is intentionally root-owned because it may contain protected
logs and config summaries.
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

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir=${1:-/tmp/gitea-incident-$timestamp}
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
    printf 'gitea_active=%s\n' "$(systemctl is-active gitea 2>/dev/null || true)"
    printf 'nginx_active=%s\n' "$(systemctl is-active nginx 2>/dev/null || true)"
    printf 'gitea_pid=%s\n' "$(pgrep -xo gitea 2>/dev/null || true)"
    printf 'kernel=%s\n' "$(uname -srmo)"
  } >"$output_dir/summary.txt"
}

capture_gitea_config_summary() {
  local app_ini=/etc/gitea/app.ini
  local output_file=$output_dir/gitea-config-summary.txt

  if [[ ! -r $app_ini ]]; then
    printf '%s is not readable on this host.\n' "$app_ini" >"$output_file"
    return 0
  fi

  log "Capturing $(basename "$output_file")"
  awk '
    BEGIN {
      print "# Safe subset of /etc/gitea/app.ini"
      print "# Secret-bearing keys are intentionally omitted."
      print ""
    }
    /^\[/ {
      section = tolower($0)
      if (section == "[server]" || section == "[database]") {
        print $0
      }
      next
    }
    /^[[:space:]]*($|;|#)/ { next }
    section == "[server]" && $1 ~ /^(DOMAIN|ROOT_URL|HTTP_PORT|PROTOCOL|SSH_DOMAIN|SSH_PORT)$/ {
      print $0
    }
    section == "[database]" && $1 ~ /^(DB_TYPE|HOST|NAME|USER|SCHEMA|SSL_MODE|PATH)$/ {
      print $0
    }
  ' "$app_ini" >"$output_file"
}

capture_route_probes() {
  local output_file=$output_dir/curl-local-routes.txt

  if ! command -v curl >/dev/null 2>&1; then
    log "Capturing $(basename "$output_file")"
    printf 'curl is not installed on this host.\n' >"$output_file"
    return 0
  fi

  log "Capturing $(basename "$output_file")"
  {
    printf '# Local Gitea route probes from %s\n\n' "$(hostname)"
    for path in / /api/healthz /Kevin-Mok; do
      printf '== %s ==\n' "$path"
      if command -v timeout >/dev/null 2>&1; then
        if ! timeout 25s curl -sS -o /dev/null \
          -w 'code=%{http_code} start=%{time_starttransfer}s total=%{time_total}s\n' \
          "http://127.0.0.1:3000$path"; then
          printf 'request_failed=1\n'
        fi
      else
        if ! curl -sS -o /dev/null \
          -w 'code=%{http_code} start=%{time_starttransfer}s total=%{time_total}s\n' \
          "http://127.0.0.1:3000$path"; then
          printf 'request_failed=1\n'
        fi
      fi
      printf '\n'
    done
  } >"$output_file" 2>&1
}

capture_process_details() {
  local gitea_pid
  gitea_pid=$(pgrep -xo gitea 2>/dev/null || true)

  if [[ -z $gitea_pid ]]; then
    printf 'No running gitea process found.\n' >"$output_dir/gitea-process.txt"
    printf 'No running gitea process found.\n' >"$output_dir/gitea-threads.txt"
    return 0
  fi

  run_capture gitea-process.txt ps -p "$gitea_pid" -o pid,ppid,user,lstart,etime,pcpu,pmem,rss,vsz,cmd
  run_capture gitea-threads.txt ps -L -p "$gitea_pid" -o pid,tid,pcpu,pmem,stat,etime,comm

  if command -v lsof >/dev/null 2>&1; then
    run_capture gitea-lsof.txt lsof -p "$gitea_pid"
  fi
}

capture_summary
run_capture systemctl-gitea.txt systemctl status gitea --no-pager
run_capture systemctl-nginx.txt systemctl status nginx --no-pager
run_capture systemctl-show-gitea.txt systemctl show gitea -p ActiveState -p SubState -p ExecMainPID -p ExecMainStartTimestamp -p FragmentPath
run_capture gitea-version.txt /usr/local/bin/gitea --version
run_capture journal-gitea.txt journalctl -u gitea --no-pager -n 300
run_capture nginx-config-test.txt nginx -t
run_capture nginx-error-tail.txt tail -n 100 /var/log/nginx/error.log
run_capture nginx-access-tail.txt tail -n 200 /var/log/nginx/access.log
capture_gitea_config_summary
capture_route_probes
capture_process_details

log "Capturing manifest.txt"
find "$output_dir" -maxdepth 1 -type f -printf '%f\n' | sort >"$output_dir/manifest.txt"

printf 'Incident bundle written to %s\n' "$output_dir"

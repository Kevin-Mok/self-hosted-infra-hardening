#!/usr/bin/env bash

set -euo pipefail

print_section() {
  printf '\n== %s ==\n' "$1"
}

print_note() {
  printf '%s\n' "$1"
}

print_warn() {
  printf 'WARN: %s\n' "$1"
}

print_fail() {
  printf 'FAIL: %s\n' "$1" >&2
}

require_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    print_fail "This script must run as root and sudo is not available"
    exit 1
  fi

  exec sudo "$0" "$@"
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/harden-phone-ssh.sh [--user USER] [--port PORT]

What this does:
  - Installs /etc/ssh/sshd_config.d/81-phone-ssh-hardening.conf
  - Restricts SSH login to the chosen user
  - Forces public-key auth as the only allowed authentication method
  - Tightens auth and connection limits to reduce spam noise and abuse
  - Validates sshd config before applying it

Options:
  --user USER   Optional. Only this user will be allowed to log in over SSH. Defaults to SUDO_USER or the current user.
  --port PORT   Optional. SSH port for status output. Defaults to 22229.
  -h, --help    Show this help text.

This script re-execs itself with sudo when you are not already root.
EOF
}

is_valid_port() {
  local value="$1"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    return 1
  fi

  return 0
}

detect_ssh_service() {
  if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -Fq 'ssh.service'; then
    printf 'ssh\n'
    return 0
  fi

  if systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -Fq 'sshd.service'; then
    printf 'sshd\n'
    return 0
  fi

  return 1
}

ssh_socket_unit_exists() {
  systemctl list-unit-files ssh.socket --no-legend 2>/dev/null | grep -Fq 'ssh.socket'
}

ssh_socket_is_enabled_or_active() {
  if ! ssh_socket_unit_exists; then
    return 1
  fi

  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    return 0
  fi

  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

ensure_sshd_runtime_dir() {
  if "${sudo_cmd[@]}" test -d /run/sshd; then
    return 0
  fi

  print_section "Preparing sshd Runtime Directory"
  "${sudo_cmd[@]}" install -d -m 755 -o root -g root /run/sshd
  print_note "Created /run/sshd for sshd validation and service startup"
}

apply_ssh_service() {
  local ssh_service="$1"

  print_section "Applying SSH Service"

  if ssh_socket_is_enabled_or_active; then
    if systemctl is-active "$ssh_service" >/dev/null 2>&1; then
      "${sudo_cmd[@]}" systemctl reload-or-restart "$ssh_service"
      print_note "Reloaded active ${ssh_service}.service while ssh.socket remains in control"
    else
      print_note "ssh.socket is active or enabled and ${ssh_service}.service is inactive"
      print_note "New sshd auth settings will apply on the next inbound connection"
    fi
    return 0
  fi

  "${sudo_cmd[@]}" systemctl enable "$ssh_service" >/dev/null
  "${sudo_cmd[@]}" systemctl reload-or-restart "$ssh_service"
  print_note "Enabled and applied ${ssh_service}.service"
}

target_user="${SUDO_USER:-$(id -un)}"
port="22229"
original_args=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --user)
      shift
      target_user="${1:-}"
      ;;
    --port)
      shift
      port="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print_fail "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if ! id "$target_user" >/dev/null 2>&1; then
  print_fail "User does not exist: $target_user"
  exit 1
fi

if ! is_valid_port "$port"; then
  print_fail "Port must be a number from 1 to 65535"
  exit 1
fi

require_root "${original_args[@]}"

sudo_cmd=()
sshd_bin="$(command -v sshd 2>/dev/null || true)"
if [ -z "$sshd_bin" ]; then
  print_fail "sshd is not installed or not on PATH. Install OpenSSH server first."
  exit 1
fi

ssh_service="$(detect_ssh_service || true)"
if [ -z "$ssh_service" ]; then
  print_fail "Could not detect ssh.service or sshd.service"
  exit 1
fi

config_dir="/etc/ssh/sshd_config.d"
config_path="${config_dir}/81-phone-ssh-hardening.conf"
tmp_config="$(mktemp)"
backup_config=""

cleanup() {
  rm -f "$tmp_config"
  if [ -n "$backup_config" ]; then
    rm -f "$backup_config"
  fi
}
trap cleanup EXIT

{
  printf '%s\n' "# Managed by fixes/scripts/harden-phone-ssh.sh"
  printf '%s\n' "AllowUsers ${target_user}"
  printf '%s\n' "AuthenticationMethods publickey"
  printf '%s\n' "PubkeyAuthentication yes"
  printf '%s\n' "PasswordAuthentication no"
  printf '%s\n' "KbdInteractiveAuthentication no"
  printf '%s\n' "PermitRootLogin no"
  printf '%s\n' "MaxAuthTries 3"
  printf '%s\n' "LoginGraceTime 20"
  printf '%s\n' "MaxStartups 10:30:30"
  printf '%s\n' "MaxSessions 4"
  printf '%s\n' "PermitUserEnvironment no"
  printf '%s\n' "AllowAgentForwarding no"
  printf '%s\n' "GatewayPorts no"
  printf '%s\n' "PermitTunnel no"
} > "$tmp_config"

print_section "Installing SSH Hardening Config"
"${sudo_cmd[@]}" install -d -m 755 "$config_dir"
if "${sudo_cmd[@]}" test -f "$config_path"; then
  backup_config="$(mktemp)"
  "${sudo_cmd[@]}" cp "$config_path" "$backup_config"
fi
"${sudo_cmd[@]}" install -m 644 "$tmp_config" "$config_path"

ensure_sshd_runtime_dir

if ! "${sudo_cmd[@]}" "$sshd_bin" -t; then
  print_fail "sshd config validation failed. Restoring previous $config_path state."
  if [ -n "$backup_config" ]; then
    "${sudo_cmd[@]}" install -m 644 "$backup_config" "$config_path"
  else
    "${sudo_cmd[@]}" rm -f "$config_path"
  fi
  exit 1
fi

apply_ssh_service "$ssh_service"

print_section "Effective SSH Hardening Settings"
"${sudo_cmd[@]}" "$sshd_bin" -T | grep -E '^(port|allowusers|authenticationmethods|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|logingracetime|maxstartups|maxsessions|permitrootlogin|permituserenvironment|allowagentforwarding|gatewayports|permittunnel) '

print_section "Next Steps"
print_note "SSH is restricted to user: ${target_user}"
print_note "Custom SSH port still expected: ${port}"
print_warn "This reduces SSH spam and abuse surface, but it does not make the host invisible on the internet."

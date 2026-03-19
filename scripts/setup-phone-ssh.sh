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
  ./scripts/setup-phone-ssh.sh --port PORT [--user USER] [--public-key PATH] [--keep-port-22]

What this does:
  - Installs /etc/ssh/sshd_config.d/80-phone-remote-access.conf
  - Switches SSH to key-only auth
  - Sets a non-default SSH port
  - Opens the chosen port in ufw or firewalld when one is active
  - Validates sshd config before reloading the SSH service

Options:
  --port PORT         Required. TCP port to expose for SSH.
  --user USER         Login user to protect from lockout. Defaults to SUDO_USER or the current user.
  --public-key PATH   Optional. Append this public key to USER's authorized_keys before hardening.
  --keep-port-22      Keep port 22 open during cutover. Rerun without this flag after verification if you want only the custom port.
  -h, --help          Show this help text.

This script re-execs itself with sudo when you are not already root.
EOF
}

is_valid_port() {
  local value="$1"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [ "$value" -lt 1024 ] || [ "$value" -gt 65535 ]; then
    return 1
  fi

  return 0
}

is_valid_public_key() {
  local key_text="$1"

  printf '%s\n' "$key_text" | grep -Eq '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) '
}

append_public_key() {
  local key_path="$1"
  local auth_dir="$2"
  local auth_keys="$3"
  local target_user="$4"
  local target_group="$5"
  local key_text

  if [ ! -r "$key_path" ]; then
    print_fail "Public key file is not readable: $key_path"
    exit 1
  fi

  key_text="$(tr -d '\r' < "$key_path")"
  if ! is_valid_public_key "$key_text"; then
    print_fail "Public key file does not look like a supported OpenSSH public key: $key_path"
    exit 1
  fi

  "${sudo_cmd[@]}" install -d -m 700 -o "$target_user" -g "$target_group" "$auth_dir"
  "${sudo_cmd[@]}" touch "$auth_keys"
  "${sudo_cmd[@]}" chown "$target_user:$target_group" "$auth_keys"
  "${sudo_cmd[@]}" chmod 600 "$auth_keys"

  if "${sudo_cmd[@]}" grep -Fqx "$key_text" "$auth_keys"; then
    print_note "Public key already present in $auth_keys"
    return 0
  fi

  printf '%s\n' "$key_text" | "${sudo_cmd[@]}" tee -a "$auth_keys" >/dev/null
  print_note "Appended public key from $key_path to $auth_keys"
}

count_authorized_keys() {
  local auth_keys="$1"

  if ! "${sudo_cmd[@]}" test -f "$auth_keys"; then
    printf '0\n'
    return 0
  fi

  "${sudo_cmd[@]}" awk '
    /^[[:space:]]*(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+/ {
      count++
    }
    END {
      print count + 0
    }
  ' "$auth_keys"
}

open_firewall_port() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -Fq 'Status: active'; then
      print_section "Firewall"
      "${sudo_cmd[@]}" ufw allow "${port}/tcp"
      print_note "Opened TCP port ${port} in ufw"
      return 0
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      print_section "Firewall"
      "${sudo_cmd[@]}" firewall-cmd --permanent --add-port="${port}/tcp"
      "${sudo_cmd[@]}" firewall-cmd --reload
      print_note "Opened TCP port ${port} in firewalld"
      return 0
    fi
  fi

  print_warn "No active ufw or firewalld instance detected. Open TCP port ${port} manually if another firewall is in use."
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

ensure_sshd_runtime_dir() {
  if "${sudo_cmd[@]}" test -d /run/sshd; then
    return 0
  fi

  print_section "Preparing sshd Runtime Directory"
  "${sudo_cmd[@]}" install -d -m 755 -o root -g root /run/sshd
  print_note "Created /run/sshd for sshd validation and service startup"
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

configure_ssh_socket_override_if_needed() {
  local socket_override_dir="/etc/systemd/system/ssh.socket.d"
  local socket_override_path="${socket_override_dir}/listen.conf"
  local socket_tmp

  if ! ssh_socket_is_enabled_or_active; then
    return 0
  fi

  socket_tmp="$(mktemp)"
  {
    printf '%s\n' "[Socket]"
    printf '%s\n' "ListenStream="
    if [ "$keep_port_22" -eq 1 ]; then
      printf '%s\n' "ListenStream=0.0.0.0:22"
      printf '%s\n' "ListenStream=[::]:22"
    fi
    printf '%s\n' "ListenStream=0.0.0.0:${port}"
    printf '%s\n' "ListenStream=[::]:${port}"
  } > "$socket_tmp"

  print_section "Configuring systemd ssh.socket"
  "${sudo_cmd[@]}" install -d -m 755 "$socket_override_dir"
  "${sudo_cmd[@]}" install -m 644 "$socket_tmp" "$socket_override_path"
  rm -f "$socket_tmp"

  "${sudo_cmd[@]}" systemctl daemon-reload
  "${sudo_cmd[@]}" systemctl restart ssh.socket
  print_note "Updated ssh.socket ListenStream entries for port ${port}"
  if [ "$keep_port_22" -eq 1 ]; then
    print_note "ssh.socket still includes port 22 for cutover"
  fi
}

apply_ssh_service() {
  local ssh_service="$1"

  print_section "Applying SSH Service"

  if ssh_socket_is_enabled_or_active; then
    print_note "ssh.socket is active or enabled, so systemd socket activation controls the listener"
    "${sudo_cmd[@]}" systemctl restart ssh.socket
    print_note "Restarted ssh.socket"
    return 0
  fi

  "${sudo_cmd[@]}" systemctl enable "$ssh_service" >/dev/null
  "${sudo_cmd[@]}" systemctl reload-or-restart "$ssh_service"
  print_note "Enabled and applied ${ssh_service}.service"
}

port=""
target_user="${SUDO_USER:-$(id -un)}"
public_key_path=""
keep_port_22=0
original_args=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      shift
      port="${1:-}"
      ;;
    --user)
      shift
      target_user="${1:-}"
      ;;
    --public-key)
      shift
      public_key_path="${1:-}"
      ;;
    --keep-port-22)
      keep_port_22=1
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

if [ -z "$port" ]; then
  print_fail "--port is required"
  usage
  exit 1
fi

if ! is_valid_port "$port"; then
  print_fail "Port must be a number from 1024 to 65535"
  exit 1
fi

if [ "$port" -eq 22 ]; then
  print_fail "Choose a non-default port instead of 22"
  exit 1
fi

if ! id "$target_user" >/dev/null 2>&1; then
  print_fail "User does not exist: $target_user"
  exit 1
fi

require_root "${original_args[@]}"

sudo_cmd=()

sshd_bin="$(command -v sshd 2>/dev/null || true)"
if [ -z "$sshd_bin" ]; then
  print_fail "sshd is not installed or not on PATH. Install OpenSSH server first."
  exit 1
fi

target_group="$(id -gn "$target_user")"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
  print_fail "Could not resolve a home directory for user: $target_user"
  exit 1
fi

auth_dir="$target_home/.ssh"
auth_keys="$auth_dir/authorized_keys"

print_section "Target Account"
print_note "User: $target_user"
print_note "Home: $target_home"
print_note "SSH port: $port"

if [ -n "$public_key_path" ]; then
  print_section "Authorized Keys"
  append_public_key "$public_key_path" "$auth_dir" "$auth_keys" "$target_user" "$target_group"
fi

authorized_key_count="$(count_authorized_keys "$auth_keys")"
if [ "$authorized_key_count" -lt 1 ]; then
  print_fail "Refusing to disable password auth because $auth_keys does not contain a valid public key."
  print_note "Add your phone's public key first, then rerun with --public-key /path/to/key.pub or manage $auth_keys manually."
  exit 1
fi

print_section "Authorized Keys"
print_note "Valid public keys found in $auth_keys: $authorized_key_count"

config_dir="/etc/ssh/sshd_config.d"
config_path="${config_dir}/80-phone-remote-access.conf"
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
  printf '%s\n' "# Managed by fixes/scripts/setup-phone-ssh.sh"
  if [ "$keep_port_22" -eq 1 ]; then
    printf '%s\n' "Port 22"
  fi
  printf '%s\n' "Port $port"
  printf '%s\n' "PubkeyAuthentication yes"
  printf '%s\n' "PasswordAuthentication no"
  printf '%s\n' "KbdInteractiveAuthentication no"
  printf '%s\n' "ChallengeResponseAuthentication no"
  printf '%s\n' "PermitEmptyPasswords no"
  printf '%s\n' "PermitRootLogin no"
  printf '%s\n' "AllowTcpForwarding yes"
  printf '%s\n' "X11Forwarding no"
  printf '%s\n' "UsePAM yes"
} > "$tmp_config"

print_section "Installing SSH Config"
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

open_firewall_port "$port"

configure_ssh_socket_override_if_needed

ssh_service="$(detect_ssh_service || true)"
if [ -z "$ssh_service" ]; then
  print_warn "Could not detect ssh.service or sshd.service. Reload SSH manually after reviewing $config_path."
else
  apply_ssh_service "$ssh_service"
fi

print_section "Effective SSH Settings"
"${sudo_cmd[@]}" "$sshd_bin" -T | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|allowtcpforwarding) '

lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

print_section "Next Steps"
if [ -n "$lan_ip" ]; then
  print_note "Router forward: external TCP ${port} -> ${lan_ip}:${port}"
else
  print_note "Router forward: external TCP ${port} -> this machine's LAN IP on port ${port}"
fi
print_note "Phone test over cellular: ssh -p ${port} ${target_user}@PUBLIC_IP"
print_note "If your public IP changes, update the IP you use or add dynamic DNS."
if [ "$keep_port_22" -eq 1 ]; then
  print_note "Port 22 is still enabled for cutover. Rerun without --keep-port-22 after the new port works."
fi
print_warn "Changing the port reduces scan noise. The real protection here is disabling password login and using SSH keys."

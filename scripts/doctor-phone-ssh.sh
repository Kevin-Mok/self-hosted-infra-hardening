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
  ./scripts/doctor-phone-ssh.sh [--port PORT]

What this does:
  - Shows whether sshd is configured for the requested port
  - Shows whether ssh.socket is overriding the listening ports
  - Shows live listening sockets on port 22 and the requested port
  - Shows ufw or firewalld state when available
  - Summarizes whether the remaining problem is on the host or outside it

Options:
  --port PORT   SSH port to inspect. Defaults to 22229.
  -h, --help    Show this help text.

This script re-execs itself with sudo when you are not already root.
EOF
}

is_valid_port() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  [ "$value" -ge 1 ] || return 1
  [ "$value" -le 65535 ] || return 1
}

port="22229"
original_args=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
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

if ! is_valid_port "$port"; then
  print_fail "Port must be a number from 1 to 65535"
  exit 1
fi

require_root "${original_args[@]}"

listener_on_port=0
ufw_open=0
firewalld_open=0
ssh_socket_present=0
ssh_socket_active=0
ssh_socket_enabled=0

print_section "Phone SSH Doctor"
printf 'Time: %s\n' "$(date -Is 2>/dev/null || date)"
printf 'Port under test: %s\n' "$port"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
fi

print_section "Network Addresses"
lan_ips="$(hostname -I 2>/dev/null || true)"
if [ -n "$lan_ips" ]; then
  printf 'LAN IPs: %s\n' "$lan_ips"
else
  print_warn "Could not determine LAN IPs with hostname -I"
fi

if command -v curl >/dev/null 2>&1; then
  public_ip="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$public_ip" ]; then
    printf 'Public IPv4: %s\n' "$public_ip"
  else
    print_warn "Could not determine public IPv4 automatically"
  fi
fi

print_section "Managed SSH Config"
if [ -f /etc/ssh/sshd_config.d/80-phone-remote-access.conf ]; then
  sed -n '1,200p' /etc/ssh/sshd_config.d/80-phone-remote-access.conf
else
  print_warn "Managed config file is missing: /etc/ssh/sshd_config.d/80-phone-remote-access.conf"
fi

print_section "Effective sshd Settings"
if command -v sshd >/dev/null 2>&1; then
  sshd -T | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|allowtcpforwarding) ' || true
else
  print_fail "sshd is not installed"
  exit 1
fi

print_section "systemd Service State"
systemctl is-active ssh.service 2>/dev/null || true
systemctl is-enabled ssh.service 2>/dev/null || true

print_section "systemd ssh.socket State"
if systemctl list-unit-files ssh.socket --no-legend 2>/dev/null | grep -Fq 'ssh.socket'; then
  ssh_socket_present=1
  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    ssh_socket_active=1
  fi
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    ssh_socket_enabled=1
  fi

  printf 'present: yes\n'
  printf 'active: %s\n' "$(systemctl is-active ssh.socket 2>/dev/null || true)"
  printf 'enabled: %s\n' "$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
  systemctl cat ssh.socket || true
else
  print_note "ssh.socket is not installed on this host"
fi

print_section "Listening Sockets"
if command -v ss >/dev/null 2>&1; then
  ss_output="$(ss -ltnp 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" || $4 ~ ":22$"')"
  if [ -n "$ss_output" ]; then
    printf '%s\n' "$ss_output"
    if printf '%s\n' "$ss_output" | grep -Eq "[.:]${port}[[:space:]]"; then
      listener_on_port=1
    fi
  else
    print_warn "No listener found on port 22 or ${port}"
  fi
else
  print_warn "ss command is not available"
fi

print_section "Local Port Probe"
if command -v nc >/dev/null 2>&1; then
  if nc -zvw3 127.0.0.1 "$port" >/tmp/phone-ssh-doctor-port-check.txt 2>&1; then
    cat /tmp/phone-ssh-doctor-port-check.txt
    listener_on_port=1
  else
    cat /tmp/phone-ssh-doctor-port-check.txt
  fi
  rm -f /tmp/phone-ssh-doctor-port-check.txt
else
  print_warn "nc is not available for local probing"
fi

print_section "Firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw_status="$(ufw status 2>/dev/null || true)"
  if [ -n "$ufw_status" ]; then
    printf '%s\n' "$ufw_status"
    if printf '%s\n' "$ufw_status" | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"; then
      ufw_open=1
    fi
  fi
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  if firewall-cmd --state >/dev/null 2>&1; then
    firewalld_ports="$(firewall-cmd --list-ports 2>/dev/null || true)"
    printf 'firewalld ports: %s\n' "$firewalld_ports"
    if printf '%s\n' "$firewalld_ports" | grep -Eq "(^| )${port}/tcp($| )"; then
      firewalld_open=1
    fi
  fi
fi

print_section "Diagnosis"
if [ "$listener_on_port" -eq 0 ]; then
  print_fail "Nothing on this host is listening on port ${port}."
  if [ "$ssh_socket_present" -eq 1 ] && { [ "$ssh_socket_active" -eq 1 ] || [ "$ssh_socket_enabled" -eq 1 ]; }; then
    print_warn "ssh.socket is present. If its ListenStream lines still only mention 22, socket activation is overriding sshd_config."
  fi
  print_note "This is a host-side issue, not a router issue."
  exit 1
fi

if [ "$ufw_open" -eq 0 ] && [ "$firewalld_open" -eq 0 ]; then
  print_warn "I did not confirm an explicit firewall allow rule for ${port}/tcp."
  print_note "If a firewall is active elsewhere, this can still block remote access."
fi

print_note "This host appears to be listening on port ${port}."
print_note "If your phone still gets 'Connection refused' from the public IP, the remaining likely causes are:"
print_note "- the router is not forwarding external ${port}/tcp to this machine"
print_note "- the router is forwarding to the wrong LAN IP"
print_note "- your ISP is using CGNAT or otherwise not allowing inbound access"
print_note "- the phone is still on Wi-Fi and hitting a different path than cellular"

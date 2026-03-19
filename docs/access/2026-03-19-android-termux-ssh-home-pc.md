# 2026-03-19 Android Termux SSH Into Home PC Through Double NAT

## Goal

Reach a home Ubuntu PC from an Android phone running Termux using direct SSH
over the public internet, while:

- moving SSH off port `22`
- disabling password login
- disabling root SSH login
- restricting SSH access to the normal login user

## Working Topology

The path that finally worked was:

```text
Android phone running Termux
  -> public IPv4 address on the internet
  -> Rogers Xfinity gateway
  -> TP-Link Archer C80
  -> Ubuntu PC running OpenSSH server
```

The important discovery was that the TP-Link router did not have the public IP
directly. Its WAN address was private, which meant there was an upstream Rogers
gateway doing another layer of NAT.

Sanitized routing model:

```text
internet public IP: <public-ip>
Rogers Xfinity gateway LAN: <gateway-lan-ip>
Archer C80 WAN: <archer-wan-ip>
Ubuntu PC LAN: <pc-lan-ip>
SSH port: 22229/tcp
```

## Commands Used

Host-side setup on the Ubuntu PC:

```bash
./scripts/setup-phone-ssh.sh \
  --port 22229 \
  --user kevin \
  --public-key /path/to/phone.pub \
  --keep-port-22
```

After SSH access worked, the extra hardening layer was applied:

```bash
./scripts/harden-phone-ssh.sh --port 22229
```

Termux login command on Android:

```bash
ssh -p 22229 kevin@<public-ip>
```

Live verification command used on the host:

```bash
sudo sshd -T | grep -E '^(port|allowusers|authenticationmethods|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
```

Expected hardening state:

```text
port 22
port 22229
allowusers kevin
authenticationmethods publickey
passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin no
```

## Host-Side SSH Changes

The working host setup included:

- `/etc/ssh/sshd_config.d/80-phone-remote-access.conf`
  - custom SSH port `22229`
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  - `PermitRootLogin no`
- `/etc/ssh/sshd_config.d/81-phone-ssh-hardening.conf`
  - `AllowUsers kevin`
  - `AuthenticationMethods publickey`
  - tighter `MaxAuthTries`, `LoginGraceTime`, and `MaxStartups`

The setup flow also had to account for host-specific service behavior:

- create `/run/sshd` before validating with `sshd -t`
- handle both `ssh.service` and `ssh.socket` style systems
- explicitly start or restart SSH if the service was inactive

## Router And Gateway Forwarding Chain

The downstream TP-Link Archer C80 forward was:

```text
External Port: 22229
Internal Port: 22229
Protocol: TCP
Internal IP: <pc-lan-ip>
```

That alone was not enough because the Archer C80 itself sat behind the Rogers
gateway. The upstream Rogers layer also had to expose the same port to the
Archer WAN address:

```text
Rogers gateway: 22229/tcp -> <archer-wan-ip>:22229
Archer C80:     22229/tcp -> <pc-lan-ip>:22229
```

Without the Rogers-side forward, the phone still received `Connection refused`
from the public IP even though the Ubuntu host was already listening locally.

## Troubleshooting Sequence That Mattered

The successful debugging order was:

1. Fix `sshd -t` failing because `/run/sshd` did not exist.
2. Check whether `ssh.socket` was overriding the expected listener port.
3. Confirm whether `ssh.service` was actually active instead of assuming the
   config reload was enough.
4. Use `./scripts/doctor-phone-ssh.sh --port 22229` to prove whether the host
   itself was listening on `22229`.
5. Only after the host was confirmed healthy, debug router and upstream gateway
   forwarding.
6. Compare the public IP seen from the internet with the Archer WAN IP to
   detect the double-NAT problem.

The doctor script was the main divider between host problems and network-edge
problems:

- if nothing listened on `22229`, the bug was still on the Ubuntu PC
- if the host listened on `22229`, the remaining problem was router, gateway,
  or ISP reachability

## Result

Android Termux was able to SSH into the Ubuntu PC over the public internet once
all of the following were true:

- the Ubuntu host was listening on `22229`
- password auth was disabled
- root SSH login was disabled
- SSH was restricted to the normal login user
- the Archer C80 forwarded `22229/tcp` to the Ubuntu PC
- the upstream Rogers Xfinity gateway forwarded `22229/tcp` to the Archer WAN
  address

## Current Security Posture

This setup is materially better than default SSH exposure on port `22`:

- random password-guessing bots cannot use password auth
- root cannot log in over SSH
- only the allowed user can log in
- the custom port cuts down background scan noise

It is still internet-exposed SSH, so it is not invisible or risk-free. The
remaining protection depends on:

- keeping the SSH key private
- keeping OpenSSH updated
- optionally adding tools like `fail2ban` if more aggressive filtering is
  needed later

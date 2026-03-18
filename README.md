# homelab-vps

Suggested GitHub description:
`Recruiter-facing ops repo for my Ubuntu OVHcloud VPS: Nginx, Gitea, personal site routing, torontozooreport.com Docker Compose, and production fixes.`

This repo documents the live service layout and operational fixes for my personal VPS. It is meant to show real infrastructure work rather than tutorial-only examples: reverse proxying, TLS termination, systemd-managed services, Docker Compose deployment, and incident response for publicly reachable domains.

## Host Profile

| Field | Value |
| --- | --- |
| Provider | OVHcloud VPS |
| Guest platform visible from the host | OpenStack Nova |
| Hostname | `vps-d7f9595b` |
| OS | `Ubuntu 25.04 (Plucky Puffin)` |
| Kernel | `Linux 6.14.0-37-generic` |

## Domains And Service Mapping

| Domain | Traffic Path | Runtime |
| --- | --- | --- |
| `kevin-mok.com` | Nginx -> `127.0.0.1:3001` | Personal site |
| `git.kevin-mok.com` | Nginx -> `127.0.0.1:3000` | Gitea managed by `systemd` |
| `torontozooreport.com` | Nginx -> `127.0.0.1:3002` | Docker Compose app from `/home/kevin/zoo-blog` |

## What This Repo Contains

- Sanitized Nginx vhost configs for each public domain
- Recommended post-incident config examples where the live snapshot should stay unchanged
- A sanitized `gitea.service` unit file
- A sanitized Docker Compose snapshot for `torontozooreport.com`
- Privileged incident capture scripts for service debugging
- Incident writeups for real outages and debugging sessions
- Access-control notes for isolated users and shared service directories
- Notes for sensitive config files that should be documented but not published verbatim

## Operational Focus

- Reverse proxying and TLS termination with Nginx and Certbot-managed certificates
- Service supervision with `systemd`
- Container orchestration with Docker Compose
- Multi-service app routing across loopback ports
- Incident capture, root-cause notes, and follow-up hardening work
- Config hygiene through redaction and documentation instead of secret leakage

## Repo Layout

```text
.
├── README.md
├── configs/
│   ├── docker/
│   ├── gitea/
│   ├── nginx/
│   └── systemd/
├── docs/
│   ├── access/
│   └── incidents/
└── scripts/
    ├── audit-gitea-state.sh
    └── capture-gitea-incident.sh
```

## Inventory

- [Gitea Nginx config](configs/nginx/gitea.conf)
- [Recommended Gitea Nginx timeout hardening](configs/nginx/gitea.recommended.conf)
- [kevin-mok.com Nginx config](configs/nginx/kevin-mok.com.conf)
- [torontozooreport.com Nginx config](configs/nginx/torontozooreport.com.conf)
- [Gitea systemd unit](configs/systemd/gitea.service)
- [torontozooreport.com Docker Compose stack](configs/docker/zoo-blog/docker-compose.yml)
- [Gitea app.ini documentation and redaction notes](configs/gitea/README.md)
- [Root-only Gitea state audit script](scripts/audit-gitea-state.sh)
- [Root-only Gitea incident capture script](scripts/capture-gitea-incident.sh)
- [2026-02-08 isolated user access note](docs/access/2026-02-08-isolated-user-shared-srv-access.md)
- [2026-03-13 Gitea 502 incident writeup](docs/incidents/2026-03-13-gitea-502-bad-gateway.md)
- [2026-03-18 Gitea spam-induced latency writeup](docs/incidents/2026-03-18-gitea-spam-induced-latency.md)

## Notes On Sanitization

- Secrets, passwords, tokens, and private key material are intentionally excluded or replaced with placeholders.
- Domain names, port bindings, upstream targets, service names, and other operationally useful values are preserved.
- Files in this repo are sanitized production snapshots, not blind copy-paste deployment artifacts.

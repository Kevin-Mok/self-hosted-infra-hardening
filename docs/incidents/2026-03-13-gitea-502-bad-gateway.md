# 2026-03-13 Gitea 502 Bad Gateway And Hanging Profile Routes

## Summary

`git.kevin-mok.com` started returning intermittent `502 Bad Gateway` responses. The failure pattern later narrowed from a generic outage to a route-specific stall: the home page could load quickly while `https://git.kevin-mok.com/Kevin-Mok` hung with no response body.

Status at the end of the debugging session:
- Mitigated temporarily by restarting Gitea
- Not confirmed as permanently fixed
- Reverse proxy ruled out as the primary fault domain

## What Users Saw

- Intermittent `502 Bad Gateway` from `git.kevin-mok.com`
- `curl https://git.kevin-mok.com/Kevin-Mok` hanging from a client machine
- Perceived "dead" behavior even when the root page sometimes still loaded

## Evidence Collected

- Nginx was up and stable, and the active vhost proxied `git.kevin-mok.com` to `127.0.0.1:3000`.
- Gitea was reachable on `127.0.0.1:3000`, so the reverse proxy target existed.
- The root route often returned `200` quickly, but `/Kevin-Mok` timed out even when tested from the VPS itself.
- `/api/healthz` was inconsistent: some responses completed in under a millisecond, while others took roughly `20-50s`.
- A single Gitea thread was repeatedly pinned near `100%` CPU during the incident.
- `systemctl daemon-reload` followed by `systemctl restart gitea` improved responsiveness, but the long stalls had already shown the issue was intermittent.

## Working Theory

The primary fault domain was Gitea, not Nginx.

The most plausible explanation from the evidence is an internal Gitea bottleneck on specific request paths, possibly tied to route-specific data access, locking, or an expensive query. The reverse proxy was forwarding correctly, but the upstream application was periodically too slow to answer.

## Immediate Mitigation

```bash
sudo systemctl daemon-reload
sudo systemctl restart gitea
```

This improved availability during the session, but it should be treated as a state reset, not a permanent fix.

## Persistent Fix Plan

1. Upgrade Gitea to the latest stable release instead of staying on `1.25.3`.
2. Inspect `/etc/gitea/app.ini` and confirm the database backend.
3. If `DB_TYPE = sqlite3`, plan a migration to PostgreSQL because intermittent lock or performance issues are a stronger risk there.
4. Add more timeout headroom in the Gitea Nginx vhost so short upstream stalls are less likely to surface as `502`.
5. Capture logs and a goroutine dump immediately on the next occurrence before restarting the service.

## Recommended Nginx Hardening

The current confirmed live snapshot stays in `configs/nginx/gitea.conf`.

A sanitized follow-up example with the proposed timeout tuning lives in:

```text
configs/nginx/gitea.recommended.conf
```

The change itself is:

```nginx
proxy_connect_timeout 10s;
proxy_send_timeout 300s;
proxy_read_timeout 300s;
```

Then validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## Next-Incident Capture Commands

For repeatable capture from this repo, run:

```bash
sudo ./scripts/capture-gitea-incident.sh
```

The script writes a timestamped bundle under `/tmp/` by default and keeps the default capture non-destructive.

If the failure appears tied to unexpected users, repositories, or registration settings, run the state audit too:

```bash
sudo ./scripts/audit-gitea-state.sh
```

That script captures a safe subset of `app.ini`, recent users and repositories from SQLite, and repository counts by owner.

If manual capture is preferred, run these before restarting Gitea:

```bash
sudo journalctl -u gitea -n 200 --no-pager
sudo grep -E "upstream|502|timed out|connect\\(\\) failed" /var/log/nginx/error.log | tail -n 100
sudo systemctl status gitea --no-pager
sudo nginx -t
sudo journalctl -u gitea -n 300 --no-pager
```

If a deeper goroutine dump is needed, trigger it separately and only with the understanding that it is more invasive than the default script capture:

```bash
sudo kill -QUIT "$(pgrep -xo gitea)"
```

## Takeaway

This incident was valuable because it separated two different failure modes:

- Nginx being unable to reach an upstream
- Gitea being reachable but internally stalled

The observed behavior matched the second case. That distinction matters because it changes the fix path from proxy debugging to application and database debugging.

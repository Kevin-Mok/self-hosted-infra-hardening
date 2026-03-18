# 2026-03-18 Gitea Spam-Induced Latency And Recovery

## Summary

`git.kevin-mok.com` became effectively unusable again on 2026-03-18. Simple restarts did not hold: the replacement `gitea` process quickly went back to saturating a CPU core, and page loads still hung for tens of seconds.

The confirmed live stack during the incident was:

- Gitea `1.25.3`
- `DB_TYPE = sqlite3`
- public unauthenticated access enabled
- public registration enabled

The key recovery step was to harden public access in `/etc/gitea/app.ini` and then restart Gitea. After that change, the spam stopped and the instance became responsive again.

## What Users Saw

- Page loads hanging for roughly `10-50s`
- Many `500 Internal Server Error` responses
- Gitea appearing "still broken" even after `sudo systemctl restart gitea`

## Evidence Collected

- Restarting Gitea replaced the process, but the new PID immediately became CPU-heavy again.
- `/etc/gitea/app.ini` confirmed `DB_TYPE = sqlite3`.
- `/home/git/.gitea/log/gitea.log` showed many requests to random junk slugs and abuse-like routes across:
  - issue lists
  - repo home pages
  - compare views
  - avatar endpoints
  - packages
  - RSS and Atom feeds
- The same log showed:
  - `DBIndexer.Search: context canceled`
  - slow SQL warnings against `commit_status`
  - slow SQL warnings against `action_task`
- Legitimate `Kevin-Mok/*` routes were also slowed or failed once the instance was under pressure.

Representative examples from the log included many requests for obviously unrelated usernames and repositories such as counterfeit-money, fake driving-license, stroller, and parrot-related slugs. That pattern strongly suggested automated abuse rather than normal traffic.

## Working Theory

This incident looked like abuse pressure amplified by the current Gitea storage choice.

Open public access and open registration allowed hostile or low-value traffic to keep reaching expensive Gitea routes. Because the instance was backed by SQLite, the resulting DB and indexer work was more likely to become a bottleneck under load. Restarting Gitea alone did not help because the same request pattern resumed immediately.

## Mitigation Applied

The live mitigation was to tighten the public access settings in `/etc/gitea/app.ini`:

```ini
[service]
DISABLE_REGISTRATION = true
ENABLE_CAPTCHA = true
REQUIRE_SIGNIN_VIEW = true

[openid]
ENABLE_OPENID_SIGNUP = false
```

Then restart Gitea:

```bash
sudo systemctl restart gitea
```

`REQUIRE_SIGNIN_VIEW = true` was appropriate here because this is a personal instance and public browsing was not required during recovery.

## Result

- The abusive traffic stopped reaching the same expensive public routes.
- Gitea returned to a responsive state.
- The service recovered without changing the Nginx vhost during this incident.

## Follow-Up

1. Keep registration disabled unless there is a deliberate need to reopen it.
2. Audit recent users and repositories with `scripts/audit-gitea-state.sh` and remove junk data if present.
3. Add Nginx rate limiting or other edge controls before reopening broad anonymous access.
4. Plan a migration from SQLite to PostgreSQL.
5. Upgrade Gitea off `1.25.3`.

## Takeaway

The important distinction here is that the service was not fixed by "just restarting Gitea". The durable part of the recovery was reducing abuse exposure on a SQLite-backed instance. That combination is what made the service stable again.

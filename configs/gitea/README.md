# Gitea Config Notes

The live Gitea config file is stored at:

```text
/etc/gitea/app.ini
```

This repo does not include a verbatim copy of that file yet for two reasons:

- it is owned outside the current user context
- it contains secrets and operationally sensitive values that should be reviewed before publication

## What To Preserve In A Public Redacted Copy

- `[server]` values such as `DOMAIN`, `ROOT_URL`, `HTTP_PORT`, `SSH_DOMAIN`, and `SSH_PORT`
- `[database]` non-secret topology such as `DB_TYPE`, host, port, database name, and username
- `[repository]` paths such as the repo root
- `[service]` flags like registration and visibility settings
- any mailer, actions, packages, or LFS settings that explain feature enablement

## What To Redact

- database passwords and credential-bearing URLs
- `SECRET_KEY`, `INTERNAL_TOKEN`, JWT secrets, session secrets, and webhook secrets
- SMTP credentials
- OAuth client secrets
- any token, password, private key, or shared secret used by integrations

## Follow-Up Checks

- Confirm whether `[database] DB_TYPE` is `sqlite3`, PostgreSQL, or MySQL.
- If the backend is `sqlite3`, treat migration planning as a priority because the March 2026 incident looked like an upstream application stall rather than a proxy failure.
- When publishing a redacted copy, keep routing and topology details intact so the config remains useful as an infrastructure snapshot.

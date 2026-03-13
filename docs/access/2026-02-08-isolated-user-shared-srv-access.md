# 2026-02-08 Isolated Login User With Shared `/srv/<shared-dir>` Access

## Goal

Create a normal login user, shown here as `<login-user>`, that:

- does not have `sudo`
- cannot enter `/home/kevin`
- can work inside `/srv/<shared-dir>`
- does not log in as the service owner for that directory

## Commands Used

These commands are reconstructed from `/home/kevin/.local/share/fish/fish_history` and confirmed against the current host state. Account and group names are redacted to generic placeholders while preserving the access model.

```bash
# Prevent other non-group users from entering Kevin's home directory.
sudo chmod 0750 /home/kevin

# Interactive developer/login account.
sudo adduser <login-user>

# Non-login service account that owns the shared app directory.
sudo adduser --system --group \
  --home /srv/<shared-dir>/ \
  --shell /usr/sbin/nologin \
  <service-user>

# Shared group for the app directory.
sudo addgroup <shared-group>
sudo usermod -aG <shared-group> <service-user>
sudo usermod -aG <shared-group> <login-user>

# Put the shared directory under the service account and shared group.
sudo chown -R <service-user>:<shared-group> /srv/<shared-dir>
sudo chmod 2770 /srv/<shared-dir>
```

History later also shows:

```bash
sudo passwd <login-user>
```

That step makes sense if password login or `su - <login-user>` testing was needed.

## Why This Works

- `/home/kevin` is `0750 kevin:kevin`, so `<login-user>` can traverse `/home` but cannot enter Kevin's home directory.
- `<login-user>` is not a member of the `sudo` group.
- `/srv/<shared-dir>` is `2770 <service-user>:<shared-group>`, so only the owner and members of `<shared-group>` can access it.
- The leading `2` in `2770` sets the setgid bit, so new files created there inherit group `<shared-group>`.
- `<service-user>` uses `/usr/sbin/nologin`, which keeps the service owner non-interactive.

## Current State Verified On 2026-03-13

The live system was verified on `2026-03-13`. The outputs below are sanitized to remove the real login, service, and group names while preserving the effective permission pattern.

```text
$ getent passwd <login-user>
<login-user>:x:1002:1002:Login User,,,:/home/<login-user>:/usr/bin/fish

$ id <login-user>
uid=1002(<login-user>) gid=1002(<login-user>) groups=1002(<login-user>),100(users),1003(<shared-group>)

$ getent group sudo
sudo:x:27:ubuntu,kevin

$ stat -c '%A %a %U %G %n' /home/kevin /srv/<shared-dir>
drwxr-x--- 750 kevin kevin /home/kevin
drwxrws--- 2770 <service-user> <shared-group> /srv/<shared-dir>
```

## Result

This setup gives `<login-user>` a regular isolated account with its own home directory, blocks access to `/home/kevin`, and grants shared access to `/srv/<shared-dir>` through group membership instead of `sudo`.

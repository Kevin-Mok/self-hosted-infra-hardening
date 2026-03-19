# ExecPlan: Document Android Termux SSH Access To Home PC

## Goal

Transfer the working phone-to-PC SSH setup from `linux-config` into this
sanitized ops repo by:

1. adding standalone setup, doctor, and hardening scripts under `scripts/`
2. documenting the actual working Android Termux -> Rogers Xfinity ->
   TP-Link Archer C80 -> Ubuntu PC access path
3. updating the README inventory so the new material is visible

## Steps

- [completed] Inspect the target repo structure and source SSH material in `linux-config`.
- [completed] Add `scripts/setup-phone-ssh.sh`, `scripts/doctor-phone-ssh.sh`, and `scripts/harden-phone-ssh.sh`.
- [completed] Add a sanitized dated access note under `docs/access/`.
- [completed] Update `README.md` layout and inventory to include the new scripts and access note.
- [completed] Verify the transferred scripts with `bash -n`, `--help`, and `git diff --check`.

## Review

- Added three self-contained SSH scripts under `scripts/`:
  - `setup-phone-ssh.sh`
  - `doctor-phone-ssh.sh`
  - `harden-phone-ssh.sh`
- Preserved the working behavior from the source repo while replacing
  `linux-config`-specific managed-file headers and script paths with
  `fixes`-repo equivalents.
- Added `docs/access/2026-03-19-android-termux-ssh-home-pc.md` documenting the
  successful Android Termux access flow, including the TP-Link Archer C80 and
  Rogers Xfinity double-NAT discovery, with sanitized IP placeholders.
- Updated `README.md` so the new scripts and access note appear in the repo
  summary, layout, and inventory.
- Verification completed with:
  - `bash -n scripts/setup-phone-ssh.sh`
  - `bash -n scripts/doctor-phone-ssh.sh`
  - `bash -n scripts/harden-phone-ssh.sh`
  - `bash scripts/setup-phone-ssh.sh --help`
  - `bash scripts/doctor-phone-ssh.sh --help`
  - `bash scripts/harden-phone-ssh.sh --help`
  - `git diff --check`

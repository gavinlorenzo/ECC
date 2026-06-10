# Bitwarden Env

This repo can run without a checked-out `.env` by using Bitwarden Secrets Manager.

## One-Time Setup

1. Create a Bitwarden Secrets Manager machine-account access token scoped to the project in `.bws-env.json`.
2. In a local shell, set `BWS_ACCESS_TOKEN` to that token.
3. Install the CLI if needed:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bws-env.ps1 install
```

4. Import the current local `.env` values into Bitwarden:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bws-env.ps1 import -CreateProject
```

If `.bws-env.json` has multiple targets, pass `-Target <name>` or `-AllTargets`.

The importer prints only key names and create/update actions, not values.

Use ignored `.bws-env.local.json` for machine-local overrides such as `projectId`.

## Daily Use

Run commands through Bitwarden so secrets exist only in the child process:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bws-env.ps1 run -- npm run scanner
```

For a non-default target, add `-Target <name>` before `--`.

Check wiring without printing values:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bws-env.ps1 status
```

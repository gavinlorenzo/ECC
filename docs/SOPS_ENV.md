# SOPS Env

This repo stores transfer-safe secrets as SOPS-encrypted dotenv files under `secrets/*.env.sops`.

## One-Time Setup

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 install
powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 keygen
```

The private age key stays outside the repo at `%APPDATA%\sops\age\keys.txt`. The public recipient is tracked in `.sops.yaml` and `.sops-env.json`.

## Encrypt Current Local Env

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 encrypt
```

For repos with multiple targets, pass `-Target <name>` or `-AllTargets`.

## Use Secrets Without Writing `.env`

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 run npm run dev
```

For a non-default target, add `-Target <name>`.

If PowerShell parsing gets in the way, use `-CommandLine`, for example:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 run -Target backend -CommandLine "npm run dev"
```

## Recreate `.env` On A New Machine

Copy `%APPDATA%\sops\age\keys.txt` to the new machine, install SOPS/age, then run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 decrypt
```

Use `-Force` to overwrite an existing local `.env`.

If you want each computer to have a separate age identity, generate a key on the new computer, add its public recipient to `.sops.yaml` and `.sops-env.json`, then re-run `encrypt` from a machine that can already decrypt the secrets.

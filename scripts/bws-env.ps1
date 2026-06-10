param(
  [Parameter(Position = 0)]
  [ValidateSet("install", "status", "import", "run")]
  [string]$Action = "status",

  [string]$Target,
  [string]$ManifestPath = ".bws-env.json",
  [switch]$AllTargets,
  [switch]$CreateProject,
  [switch]$DryRun,
  [switch]$IncludeEmpty,
  [switch]$NoInheritEnv,
  [switch]$NoProject,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Command
)

$ErrorActionPreference = "Stop"

$BwsVersion = "2.0.0"
$BwsTag = "bws-v$BwsVersion"
$WindowsAsset = "bws-x86_64-pc-windows-msvc-$BwsVersion.zip"
$WindowsSha256 = "4284944F3B0C7B97A4D4105C715CD814C744CEFF0405481A213937955E31D866"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\BitwardenSecretsManager"
$InstalledBws = Join-Path $InstallDir "bws.exe"

function Get-RepoRoot {
  $root = & git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $root) {
    return ($root | Select-Object -First 1)
  }
  return (Get-Location).Path
}

function Resolve-FromRoot([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return (Join-Path $script:RepoRoot $Path)
}

function Find-Bws {
  if ($env:BWS_CLI_PATH -and (Test-Path -LiteralPath $env:BWS_CLI_PATH)) {
    return $env:BWS_CLI_PATH
  }

  $cmd = Get-Command bws -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }

  if (Test-Path -LiteralPath $InstalledBws) {
    return $InstalledBws
  }

  throw "bws CLI not found. Run: powershell -ExecutionPolicy Bypass -File scripts\bws-env.ps1 install"
}

function Install-Bws {
  if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is not set; set BWS_CLI_PATH to an existing bws binary instead."
  }

  $zipPath = Join-Path $env:TEMP $WindowsAsset
  $extractDir = Join-Path $env:TEMP "bws-$BwsVersion-extract"
  $url = "https://github.com/bitwarden/sdk-sm/releases/download/$BwsTag/$WindowsAsset"

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

  $client = New-Object System.Net.WebClient
  $client.Headers.Add("User-Agent", "bws-env.ps1")
  $client.DownloadFile($url, $zipPath)

  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash
  if ($actual -ne $WindowsSha256) {
    throw "Checksum mismatch for $WindowsAsset. Expected $WindowsSha256, got $actual."
  }

  if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

  $binary = Get-ChildItem -Path $extractDir -Recurse -Filter bws.exe | Select-Object -First 1
  if (-not $binary) {
    throw "bws.exe was not found in $WindowsAsset."
  }

  Copy-Item -LiteralPath $binary.FullName -Destination $InstalledBws -Force
  & $InstalledBws --version
  Write-Host "Installed bws to $InstalledBws"
}

function Read-Manifest {
  $path = Resolve-FromRoot $ManifestPath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Manifest not found: $path"
  }

  $manifest = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
  if (-not $manifest.targets) {
    throw "Manifest must contain a targets object."
  }

  $localPath = Join-Path $script:RepoRoot ".bws-env.local.json"
  if (Test-Path -LiteralPath $localPath) {
    $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json
    if ($local.defaultTarget) {
      $manifest | Add-Member -NotePropertyName defaultTarget -NotePropertyValue $local.defaultTarget -Force
    }
    if ($local.targets) {
      foreach ($target in $local.targets.PSObject.Properties) {
        $existing = $manifest.targets.PSObject.Properties[$target.Name]
        if (-not $existing) {
          $manifest.targets | Add-Member -NotePropertyName $target.Name -NotePropertyValue $target.Value -Force
          continue
        }

        foreach ($property in $target.Value.PSObject.Properties) {
          $existing.Value | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
      }
    }
  }
  return $manifest
}

function Get-TargetNames($Manifest) {
  $names = @()
  foreach ($prop in $Manifest.targets.PSObject.Properties) {
    $names += $prop.Name
  }
  return $names
}

function Resolve-Targets($Manifest) {
  if ($AllTargets) {
    return Get-TargetNames $Manifest
  }

  if ($Target) {
    return @($Target)
  }

  if ($Manifest.defaultTarget) {
    return @([string]$Manifest.defaultTarget)
  }

  $names = Get-TargetNames $Manifest
  if ($names.Count -eq 1) {
    return @($names[0])
  }

  throw "Specify -Target. Available targets: $($names -join ', ')"
}

function Get-TargetConfig($Manifest, [string]$Name) {
  $prop = $Manifest.targets.PSObject.Properties[$Name]
  if (-not $prop) {
    $names = Get-TargetNames $Manifest
    throw "Unknown target '$Name'. Available targets: $($names -join ', ')"
  }
  return $prop.Value
}

function Convert-EnvValue([string]$Value) {
  $trimmed = $Value.Trim()
  if ($trimmed.Length -ge 2) {
    $first = $trimmed[0]
    $last = $trimmed[$trimmed.Length - 1]
    if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
      return $trimmed.Substring(1, $trimmed.Length - 2)
    }
  }
  return $trimmed
}

function Read-EnvFile([string]$Path) {
  $resolved = Resolve-FromRoot $Path
  if (-not (Test-Path -LiteralPath $resolved)) {
    throw "Env file not found: $resolved"
  }

  $entries = @()
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $resolved) {
    $lineNumber += 1
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) {
      continue
    }

    if ($trimmed.StartsWith("export ")) {
      $trimmed = $trimmed.Substring(7).TrimStart()
    }

    $match = [regex]::Match($trimmed, "^([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")
    if (-not $match.Success) {
      Write-Warning "Skipping unsupported env line in ${Path}:$lineNumber"
      continue
    }

    $entries += [PSCustomObject]@{
      Key = $match.Groups[1].Value
      Value = Convert-EnvValue $match.Groups[2].Value
      Source = $Path
      Line = $lineNumber
    }
  }
  return $entries
}

function Read-TargetEnvEntries($Config) {
  if (-not $Config.envFiles) {
    throw "Target is missing envFiles."
  }

  $entries = @()
  foreach ($envFile in $Config.envFiles) {
    $entries += Read-EnvFile ([string]$envFile.path)
  }

  $byKey = @{}
  foreach ($entry in $entries) {
    if ($byKey.ContainsKey($entry.Key) -and $byKey[$entry.Key].Value -ne $entry.Value) {
      throw "Duplicate key '$($entry.Key)' has different values across env files. Split this target or align the values."
    }
    $byKey[$entry.Key] = $entry
  }

  return $byKey.Values | Sort-Object Key
}

function Require-Token {
  if ([string]::IsNullOrWhiteSpace($env:BWS_ACCESS_TOKEN)) {
    throw "BWS_ACCESS_TOKEN is not set. Create a Bitwarden Secrets Manager machine-account token and set it in this shell."
  }
}

function Get-BwsJson([string[]]$Args) {
  $output = & $script:BwsPath @Args
  if ($LASTEXITCODE -ne 0) {
    throw "bws command failed: bws $($Args -join ' ')"
  }
  if (-not $output) {
    return $null
  }
  return ($output | Out-String | ConvertFrom-Json)
}

function Resolve-Project($Config) {
  if ($Config.projectId) {
    return [PSCustomObject]@{ Id = [string]$Config.projectId; Name = [string]$Config.projectName }
  }

  if (-not $Config.projectName) {
    throw "Target must define projectName or projectId."
  }

  $projects = Get-BwsJson @("project", "list", "--output", "json")
  $matches = @($projects | Where-Object { $_.name -eq $Config.projectName })

  if ($matches.Count -gt 1) {
    throw "Multiple Bitwarden projects named '$($Config.projectName)' are visible to this token. Set projectId in .bws-env.json."
  }

  if ($matches.Count -eq 1) {
    return [PSCustomObject]@{ Id = [string]$matches[0].id; Name = [string]$matches[0].name }
  }

  if (-not $CreateProject) {
    throw "Bitwarden project '$($Config.projectName)' was not found. Re-run with -CreateProject to create it."
  }

  $created = Get-BwsJson @("project", "create", [string]$Config.projectName, "--output", "json")
  return [PSCustomObject]@{ Id = [string]$created.id; Name = [string]$created.name }
}

function Import-Target([string]$Name, $Config) {
  Require-Token
  $project = Resolve-Project $Config
  $entries = @(Read-TargetEnvEntries $Config)
  $entries = @($entries | Where-Object { $IncludeEmpty -or $_.Value.Length -gt 0 })

  $secrets = @(Get-BwsJson @("secret", "list", $project.Id, "--output", "json"))
  $existingByKey = @{}
  foreach ($secret in $secrets) {
    if ($existingByKey.ContainsKey($secret.key)) {
      throw "Bitwarden project '$($project.Name)' contains duplicate key '$($secret.key)'. Resolve that before importing."
    }
    $existingByKey[$secret.key] = $secret
  }

  $created = 0
  $updated = 0
  foreach ($entry in $entries) {
    if ($existingByKey.ContainsKey($entry.Key)) {
      $updated += 1
      if ($DryRun) {
        Write-Host "[$Name] would update $($entry.Key)"
      } else {
        & $script:BwsPath secret edit $existingByKey[$entry.Key].id --value $entry.Value --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed updating $($entry.Key)" }
        Write-Host "[$Name] updated $($entry.Key)"
      }
    } else {
      $created += 1
      if ($DryRun) {
        Write-Host "[$Name] would create $($entry.Key)"
      } else {
        $note = "Imported from $($entry.Source) by scripts/bws-env.ps1"
        & $script:BwsPath secret create $entry.Key $entry.Value $project.Id --note $note --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed creating $($entry.Key)" }
        Write-Host "[$Name] created $($entry.Key)"
      }
    }
  }

  Write-Host "[$Name] import complete: $created create(s), $updated update(s), $($entries.Count) key(s) considered."
}

function Show-Status($Manifest) {
  Write-Host "repo: $script:RepoRoot"
  Write-Host "manifest: $(Resolve-FromRoot $ManifestPath)"
  $localPath = Join-Path $script:RepoRoot ".bws-env.local.json"
  if (Test-Path -LiteralPath $localPath) {
    Write-Host "local override: $localPath"
  }

  try {
    $bws = Find-Bws
    $version = & $bws --version
    Write-Host "bws: $bws ($version)"
  } catch {
    Write-Host "bws: missing"
  }

  if ([string]::IsNullOrWhiteSpace($env:BWS_ACCESS_TOKEN)) {
    Write-Host "BWS_ACCESS_TOKEN: not set"
  } else {
    Write-Host "BWS_ACCESS_TOKEN: set"
  }

  foreach ($name in (Resolve-Targets $Manifest)) {
    $config = Get-TargetConfig $Manifest $name
    Write-Host ""
    Write-Host "target: $name"
    Write-Host "project: $($config.projectName)"

    foreach ($envFile in $config.envFiles) {
      $path = [string]$envFile.path
      $resolved = Resolve-FromRoot $path
      if (Test-Path -LiteralPath $resolved) {
        $count = @(Read-EnvFile $path).Count
        Write-Host "env: $path ($count key(s))"
      } else {
        Write-Host "env: $path (missing)"
      }
      if ($envFile.example) {
        Write-Host "example: $($envFile.example)"
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:BWS_ACCESS_TOKEN)) {
      try {
        $project = Resolve-Project $config
        $secrets = @(Get-BwsJson @("secret", "list", $project.Id, "--output", "json"))
        Write-Host "bitwarden: $($project.Name) ($($secrets.Count) secret(s))"
      } catch {
        Write-Host "bitwarden: $($_.Exception.Message)"
      }
    }
  }
}

$script:RepoRoot = Get-RepoRoot

if ($Action -eq "install") {
  Install-Bws
  exit 0
}

$manifest = Read-Manifest
$script:BwsPath = $null
try {
  $script:BwsPath = Find-Bws
} catch {
  if ($Action -ne "status") {
    throw
  }
}

switch ($Action) {
  "status" {
    Show-Status $manifest
  }
  "import" {
    foreach ($name in (Resolve-Targets $manifest)) {
      Import-Target $name (Get-TargetConfig $manifest $name)
    }
  }
  "run" {
    if (-not $Command -or $Command.Count -eq 0) {
      throw "Usage: scripts\bws-env.ps1 run [-Target name] -- <command>"
    }
    if ($Command[0] -eq "--") {
      $Command = @($Command | Select-Object -Skip 1)
    }
    if (-not $Command -or $Command.Count -eq 0) {
      throw "Usage: scripts\bws-env.ps1 run [-Target name] -- <command>"
    }

    Require-Token
    $args = @("run")
    if ($NoInheritEnv) {
      $args += "--no-inherit-env"
    }
    if (-not $NoProject) {
      $names = @(Resolve-Targets $manifest)
      if ($names.Count -ne 1) {
        throw "run supports one target at a time. Use -Target or -NoProject."
      }
      $project = Resolve-Project (Get-TargetConfig $manifest $names[0])
      $args += @("--project-id", $project.Id)
    }
    $args += "--"
    $args += $Command

    & $script:BwsPath @args
    exit $LASTEXITCODE
  }
}

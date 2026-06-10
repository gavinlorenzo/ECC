param(
  [Parameter(Position = 0)]
  [ValidateSet("install", "keygen", "status", "encrypt", "decrypt", "run")]
  [string]$Action = "status",

  [string]$Target,
  [string]$ManifestPath = ".sops-env.json",
  [switch]$AllTargets,
  [switch]$Force,
  [string]$CommandLine,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Command
)

$ErrorActionPreference = "Stop"

$SopsVersion = "3.13.1"
$SopsAsset = "sops-v$SopsVersion.amd64.exe"
$SopsSha256 = "4654E53FFF6D0A1842FACD3A0ED5A66A8AB6164004B0AD4CA2D5E2B1C5473B65"
$AgeVersion = "1.3.1"
$AgeAsset = "age-v$AgeVersion-windows-amd64.zip"
$AgeSha256 = "C56E8CE22F7E80CB85AD946CC82D198767B056366201D3E1A2B93D865BE38154"
$ToolsRoot = Join-Path $env:LOCALAPPDATA "Programs\SopsAge"
$LocalSops = Join-Path $ToolsRoot "sops\sops.exe"
$LocalAge = Join-Path $ToolsRoot "age\age.exe"
$LocalAgeKeygen = Join-Path $ToolsRoot "age\age-keygen.exe"

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

function Find-Exe([string]$EnvName, [string]$CommandName, [string]$LocalPath) {
  $override = [Environment]::GetEnvironmentVariable($EnvName, "Process")
  if ($override -and (Test-Path -LiteralPath $override)) {
    return $override
  }
  $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  if (Test-Path -LiteralPath $LocalPath) {
    return $LocalPath
  }
  throw "$CommandName not found. Run: powershell -ExecutionPolicy Bypass -File scripts\sops-env.ps1 install"
}

function Install-SopsAge {
  if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is not set."
  }

  $tmp = Join-Path $env:TEMP "sops-age-install"
  $sopsDir = Join-Path $ToolsRoot "sops"
  $ageDir = Join-Path $ToolsRoot "age"
  New-Item -ItemType Directory -Force -Path $tmp,$sopsDir,$ageDir | Out-Null

  $client = New-Object System.Net.WebClient
  $client.Headers.Add("User-Agent", "sops-env.ps1")

  $sopsTmp = Join-Path $tmp $SopsAsset
  $client.DownloadFile("https://github.com/getsops/sops/releases/download/v$SopsVersion/$SopsAsset", $sopsTmp)
  $sopsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sopsTmp).Hash
  if ($sopsHash -ne $SopsSha256) {
    throw "SOPS checksum mismatch. Expected $SopsSha256, got $sopsHash."
  }
  Copy-Item -LiteralPath $sopsTmp -Destination $LocalSops -Force

  $ageTmp = Join-Path $tmp $AgeAsset
  $ageExtract = Join-Path $tmp "age-v$AgeVersion-windows-amd64"
  $client.DownloadFile("https://github.com/FiloSottile/age/releases/download/v$AgeVersion/$AgeAsset", $ageTmp)
  $ageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ageTmp).Hash
  if ($ageHash -ne $AgeSha256) {
    throw "age checksum mismatch. Expected $AgeSha256, got $ageHash."
  }
  if (Test-Path -LiteralPath $ageExtract) {
    Remove-Item -LiteralPath $ageExtract -Recurse -Force
  }
  Expand-Archive -LiteralPath $ageTmp -DestinationPath $ageExtract -Force
  $age = Get-ChildItem -Path $ageExtract -Recurse -Filter age.exe | Select-Object -First 1
  $ageKeygen = Get-ChildItem -Path $ageExtract -Recurse -Filter age-keygen.exe | Select-Object -First 1
  if (-not $age -or -not $ageKeygen) {
    throw "age.exe or age-keygen.exe not found in $AgeAsset."
  }
  Copy-Item -LiteralPath $age.FullName -Destination $LocalAge -Force
  Copy-Item -LiteralPath $ageKeygen.FullName -Destination $LocalAgeKeygen -Force

  & $LocalSops --version
  & $LocalAge --version
  Write-Host "Installed SOPS/age to $ToolsRoot"
}

function Get-AgeKeyFile {
  if ($env:SOPS_AGE_KEY_FILE) {
    return $env:SOPS_AGE_KEY_FILE
  }
  if (-not $env:APPDATA) {
    throw "APPDATA is not set. Set SOPS_AGE_KEY_FILE to an age key path."
  }
  return (Join-Path $env:APPDATA "sops\age\keys.txt")
}

function Set-AgeKeyAcl([string]$Path) {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $acl = New-Object System.Security.AccessControl.FileSecurity
  $acl.SetOwner([System.Security.Principal.NTAccount]$identity)
  $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
  $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
  $propagation = [System.Security.AccessControl.PropagationFlags]::None
  $type = [System.Security.AccessControl.AccessControlType]::Allow
  foreach ($account in @($identity, "NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, $rights, $inheritance, $propagation, $type)
    $acl.AddAccessRule($rule) | Out-Null
  }
  $acl.SetAccessRuleProtection($true, $false)
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Ensure-AgeKey {
  $path = Get-AgeKeyFile
  $created = $false
  if (-not (Test-Path -LiteralPath $path)) {
    $ageKeygen = Find-Exe "AGE_KEYGEN_BIN_PATH" "age-keygen" $LocalAgeKeygen
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $err = New-TemporaryFile
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $ageKeygen -o $path 2>$err.FullName | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    Remove-Item -LiteralPath $err.FullName -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) {
      throw "age-keygen failed."
    }
    $created = $true
  }
  if ($created) {
    Set-AgeKeyAcl $path
  }
  return $path
}

function Get-AgeRecipient([string]$KeyFile) {
  $match = Select-String -LiteralPath $KeyFile -Pattern "^# public key: (age1[0-9a-z]+)" | Select-Object -First 1
  if (-not $match) {
    throw "Public age recipient not found in $KeyFile."
  }
  return $match.Matches[0].Groups[1].Value
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
  $localPath = Join-Path $script:RepoRoot ".sops-env.local.json"
  if (Test-Path -LiteralPath $localPath) {
    $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json
    if ($local.defaultTarget) {
      $manifest | Add-Member -NotePropertyName defaultTarget -NotePropertyValue $local.defaultTarget -Force
    }
    if ($local.ageRecipients) {
      $manifest | Add-Member -NotePropertyName ageRecipients -NotePropertyValue $local.ageRecipients -Force
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
  return @($Manifest.targets.PSObject.Properties | ForEach-Object { $_.Name })
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
    throw "Unknown target '$Name'. Available targets: $((Get-TargetNames $Manifest) -join ', ')"
  }
  return $prop.Value
}

function Get-Recipients($Manifest, $Config) {
  $values = @()
  if ($Config.ageRecipients) {
    $values += @($Config.ageRecipients)
  } elseif ($Config.ageRecipient) {
    $values += @([string]$Config.ageRecipient)
  } elseif ($Manifest.ageRecipients) {
    $values += @($Manifest.ageRecipients)
  } elseif ($Manifest.ageRecipient) {
    $values += @([string]$Manifest.ageRecipient)
  }
  $values = @($values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($values.Count -eq 0) {
    throw "No ageRecipients configured in $ManifestPath."
  }
  return ($values -join ",")
}

function Convert-DotenvValue([string]$Value) {
  $trimmed = $Value.Trim()
  if ($trimmed.Length -ge 2) {
    $first = $trimmed[0]
    $last = $trimmed[$trimmed.Length - 1]
    if ($first -eq '"' -and $last -eq '"') {
      $inner = $trimmed.Substring(1, $trimmed.Length - 2)
      return ($inner -replace '\\n', "`n" -replace '\\r', "`r" -replace '\\t', "`t" -replace '\\"', '"' -replace '\\\\', '\')
    }
    if ($first -eq "'" -and $last -eq "'") {
      return $trimmed.Substring(1, $trimmed.Length - 2)
    }
  }
  return $trimmed
}

function Read-DotenvText([string]$Text) {
  $entries = @{}
  $lineNumber = 0
  foreach ($line in ($Text -split "`r?`n")) {
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
      Write-Warning "Skipping unsupported dotenv line $lineNumber"
      continue
    }
    $entries[$match.Groups[1].Value] = Convert-DotenvValue $match.Groups[2].Value
  }
  return $entries
}

function Read-DotenvFile([string]$Path) {
  $resolved = Resolve-FromRoot $Path
  if (-not (Test-Path -LiteralPath $resolved)) {
    throw "Env file not found: $resolved"
  }
  return Read-DotenvText (Get-Content -Raw -LiteralPath $resolved)
}

function New-SopsDotenvInput([string]$EnvFile) {
  $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("sops-env-" + [System.Guid]::NewGuid().ToString("N") + ".env")
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed.StartsWith("export ")) {
      $trimmed = $trimmed.Substring(7).TrimStart()
    }
    if ($trimmed -match "^[A-Za-z_][A-Za-z0-9_]*\s*=") {
      $lines.Add($trimmed)
    } else {
      Write-Warning "Skipping unsupported dotenv line while preparing SOPS input."
    }
  }
  [System.IO.File]::WriteAllLines($temp, $lines, [System.Text.Encoding]::UTF8)
  return $temp
}

function With-SopsKey([scriptblock]$ScriptBlock) {
  $keyFile = Ensure-AgeKey
  $oldKey = $env:SOPS_AGE_KEY_FILE
  $env:SOPS_AGE_KEY_FILE = $keyFile
  try {
    & $ScriptBlock
  } finally {
    if ($oldKey) {
      $env:SOPS_AGE_KEY_FILE = $oldKey
    } else {
      Remove-Item Env:\SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }
}

function Encrypt-Target([string]$Name, $Manifest, $Config) {
  $envFile = Resolve-FromRoot ([string]$Config.envFile)
  $encryptedFile = Resolve-FromRoot ([string]$Config.encryptedFile)
  if (-not (Test-Path -LiteralPath $envFile)) {
    Write-Host "[$Name] skipped; missing $($Config.envFile)"
    return
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $encryptedFile) | Out-Null
  $recipients = Get-Recipients $Manifest $Config
  $filenameOverride = ([string]$Config.encryptedFile) -replace "\\", "/"
  $sopsInput = New-SopsDotenvInput $envFile
  try {
    & $script:SopsPath --encrypt --filename-override $filenameOverride --input-type dotenv --output-type dotenv --age $recipients --output $encryptedFile $sopsInput
    if ($LASTEXITCODE -ne 0) {
      throw "SOPS encrypt failed for $Name."
    }
  } finally {
    Remove-Item -LiteralPath $sopsInput -Force -ErrorAction SilentlyContinue
  }
  $count = (Read-DotenvFile ([string]$Config.envFile)).Count
  Write-Host "[$Name] encrypted $count key(s) to $($Config.encryptedFile)"
}

function Decrypt-TargetToFile([string]$Name, $Config) {
  $envFile = Resolve-FromRoot ([string]$Config.envFile)
  $encryptedFile = Resolve-FromRoot ([string]$Config.encryptedFile)
  if (-not (Test-Path -LiteralPath $encryptedFile)) {
    throw "Encrypted file not found for ${Name}: $encryptedFile"
  }
  if ((Test-Path -LiteralPath $envFile) -and -not $Force) {
    throw "$($Config.envFile) already exists. Re-run with -Force to overwrite."
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $envFile) | Out-Null
  & $script:SopsPath --decrypt --input-type dotenv --output-type dotenv --output $envFile $encryptedFile
  if ($LASTEXITCODE -ne 0) {
    throw "SOPS decrypt failed for $Name."
  }
  Write-Host "[$Name] wrote $($Config.envFile)"
}

function Decrypt-TargetToEntries([string]$Name, $Config) {
  $encryptedFile = Resolve-FromRoot ([string]$Config.encryptedFile)
  if (-not (Test-Path -LiteralPath $encryptedFile)) {
    throw "Encrypted file not found for ${Name}: $encryptedFile"
  }
  $err = New-TemporaryFile
  try {
    $output = & $script:SopsPath --decrypt --input-type dotenv --output-type dotenv $encryptedFile 2>$err.FullName
    if ($LASTEXITCODE -ne 0) {
      $message = Get-Content -Raw -LiteralPath $err.FullName
      throw "SOPS decrypt failed for ${Name}: $message"
    }
    return ,(Read-DotenvText ($output -join "`n"))
  } finally {
    Remove-Item -LiteralPath $err.FullName -Force -ErrorAction SilentlyContinue
  }
}

function Show-Status($Manifest) {
  Write-Host "repo: $script:RepoRoot"
  Write-Host "manifest: $(Resolve-FromRoot $ManifestPath)"
  if (Test-Path -LiteralPath (Join-Path $script:RepoRoot ".sops-env.local.json")) {
    Write-Host "local override: $(Join-Path $script:RepoRoot ".sops-env.local.json")"
  }
  try {
    $sops = Find-Exe "SOPS_BIN_PATH" "sops" $LocalSops
    $sopsVersionText = (& $sops --version 2>$null | Select-Object -First 1)
    Write-Host "sops: $sops ($sopsVersionText)"
  } catch {
    Write-Host "sops: missing"
  }
  try {
    $age = Find-Exe "AGE_BIN_PATH" "age" $LocalAge
    Write-Host "age: $age ($(& $age --version))"
  } catch {
    Write-Host "age: missing"
  }
  $keyFile = Get-AgeKeyFile
  if (Test-Path -LiteralPath $keyFile) {
    Write-Host "age key: $keyFile"
    try { Write-Host "age recipient: $(Get-AgeRecipient $keyFile)" } catch {}
  } else {
    Write-Host "age key: missing ($keyFile)"
  }
  foreach ($name in (Resolve-Targets $Manifest)) {
    $config = Get-TargetConfig $Manifest $name
    $envFile = Resolve-FromRoot ([string]$config.envFile)
    $encryptedFile = Resolve-FromRoot ([string]$config.encryptedFile)
    $envStatus = "missing"
    if (Test-Path -LiteralPath $envFile) {
      $envCount = (Read-DotenvFile ([string]$config.envFile)).Count
      $envStatus = "$envCount key(s)"
    }
    $encryptedStatus = "missing"
    if (Test-Path -LiteralPath $encryptedFile) {
      $encryptedStatus = "present"
    }
    Write-Host ""
    Write-Host "target: $name"
    Write-Host "env: $($config.envFile) ($envStatus)"
    Write-Host "encrypted: $($config.encryptedFile) ($encryptedStatus)"
    if ($config.example) {
      Write-Host "example: $($config.example)"
    }
  }
}

$script:RepoRoot = Get-RepoRoot

if ($Action -eq "install") {
  Install-SopsAge
  exit 0
}

$manifest = Read-Manifest
$script:SopsPath = $null
try {
  $script:SopsPath = Find-Exe "SOPS_BIN_PATH" "sops" $LocalSops
} catch {
  if ($Action -notin @("status", "keygen")) {
    throw
  }
}

switch ($Action) {
  "keygen" {
    $keyFile = Ensure-AgeKey
    Write-Host "age key: $keyFile"
    Write-Host "age recipient: $(Get-AgeRecipient $keyFile)"
  }
  "status" {
    Show-Status $manifest
  }
  "encrypt" {
    foreach ($name in (Resolve-Targets $manifest)) {
      Encrypt-Target $name $manifest (Get-TargetConfig $manifest $name)
    }
  }
  "decrypt" {
    With-SopsKey {
      foreach ($name in (Resolve-Targets $manifest)) {
        Decrypt-TargetToFile $name (Get-TargetConfig $manifest $name)
      }
    }
  }
  "run" {
    if ($CommandLine) {
      $Command = @("cmd.exe", "/d", "/s", "/c", $CommandLine)
    }
    if (-not $Command -or $Command.Count -eq 0) {
      throw "Usage: scripts\sops-env.ps1 run [-Target name] <command>"
    }
    if ($Command[0] -eq "--") {
      $Command = @($Command | Select-Object -Skip 1)
    }
    if (-not $Command -or $Command.Count -eq 0) {
      throw "Usage: scripts\sops-env.ps1 run [-Target name] <command>"
    }
    $names = @(Resolve-Targets $manifest)
    if ($names.Count -ne 1) {
      throw "run supports one target at a time. Use -Target."
    }
    $entries = With-SopsKey {
      Decrypt-TargetToEntries $names[0] (Get-TargetConfig $manifest $names[0])
    }
    $oldValues = @{}
    foreach ($key in $entries.Keys) {
      $oldValues[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
      [Environment]::SetEnvironmentVariable($key, [string]$entries[$key], "Process")
    }
    try {
      $exe = $Command[0]
      $args = @($Command | Select-Object -Skip 1)
      & $exe @args
      exit $LASTEXITCODE
    } finally {
      foreach ($key in $entries.Keys) {
        [Environment]::SetEnvironmentVariable($key, $oldValues[$key], "Process")
      }
    }
  }
}

# HMD-IndexHandler.ps1
# Index load/save/migration helpers for HMD (indexVersion 2).

Set-StrictMode -Version Latest

function New-HMDIndexObject {
  return [pscustomobject]@{
    indexVersion = 2
    schema = [pscustomobject]@{
      name = "HMDInstallIndex"
      updatedAt = (Get-Date).ToString("s")
    }
    mods = @()
  }
}

function ConvertTo-HMDIndexV2([object]$index) {
  if (-not $index) {
    return New-HMDIndexObject
  }

  if ($index -is [System.Array]) {
    $newIndex = New-HMDIndexObject
    $newIndex.mods = @($index)
    return $newIndex
  }

  $hasVersion = $null -ne $index.PSObject.Properties["indexVersion"]
  if ($hasVersion -and $index.indexVersion -eq 2) {
    if ($null -eq $index.mods) { $index | Add-Member -NotePropertyName mods -NotePropertyValue @() }
    $index.mods = @($index.mods)
    if ($null -eq $index.schema) {
      $index | Add-Member -NotePropertyName schema -NotePropertyValue ([pscustomobject]@{ name = "HMDInstallIndex"; updatedAt = (Get-Date).ToString("s") })
    }
    return $index
  }

  # Treat missing/old version as v1 and migrate to v2.
  $migrated = New-HMDIndexObject
  if ($null -ne $index.PSObject.Properties["mods"]) {
    $migrated.mods = @($index.mods)
  }
  return $migrated
}

function Get-HMDIndex([string]$path) {
  if (!(Test-Path -LiteralPath $path)) {
    return New-HMDIndexObject
  }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $data = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    # Corrupt or unreadable index; start fresh.
    return New-HMDIndexObject
  }
  return ConvertTo-HMDIndexV2 $data
}

function Set-HMDIndex([string]$path, [object]$index) {
  $index = ConvertTo-HMDIndexV2 $index
  $index.schema.updatedAt = (Get-Date).ToString("s")
  $json = $index | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Update-HMDIndex([object]$index, [object]$entry) {
  $index = ConvertTo-HMDIndexV2 $index
  $mods = @($index.mods)

  if ($entry.fileId) {
    $mods = @($mods | Where-Object { $_.fileId -ne $entry.fileId })
  } elseif ($entry.modName -and $entry.version) {
    $mods = @($mods | Where-Object { $_.modName -ne $entry.modName -or $_.version -ne $entry.version })
  } elseif ($entry.fileName) {
    $mods = @($mods | Where-Object { $_.fileName -ne $entry.fileName })
  }

  $mods += [pscustomobject]$entry
  $index.mods = $mods
  return $index
}

function Remove-HMDIndexEntries([object]$index, [scriptblock]$predicate) {
  $index = ConvertTo-HMDIndexV2 $index
  $index.mods = @($index.mods | Where-Object { -not (& $predicate $_) })
  return $index
}

function Find-HMDIndexEntries([object]$index, [scriptblock]$predicate) {
  $index = ConvertTo-HMDIndexV2 $index
  return @($index.mods | Where-Object { & $predicate $_ })
}

function Get-HMDFileHash([string]$path) {
  if (!(Test-Path -LiteralPath $path)) { return $null }
  try {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
  } catch {
    return $null
  }
}

function Get-HMDManifestFieldValue([string]$text, [string]$key) {
  $k = [regex]::Escape($key)
  $patterns = @(
    '"{0}"\s*:\s*"([^"]*)"' -f $k
  )
  foreach ($pattern in $patterns) {
    $m = [regex]::Match($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      return $m.Groups[1].Value.Trim()
    }
  }
  return $null
}

function Get-HMDModManifestInfo {
  param(
    [string]$filePath,
    [scriptblock]$onLog
  )

  try {
    $zip = [IO.Compression.ZipFile]::OpenRead($filePath)
  } catch {
    if ($onLog) { & $onLog ("Not a zip or cannot open: {0}" -f $filePath) "warn" }
    return $null
  }

  $entry = $null
  $reader = $null
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -match '(^|/|\\)manifest\.json$' } | Select-Object -First 1
    if (-not $entry) {
      if ($onLog) { & $onLog "manifest.json not found in mod file." "warn" }
      return $null
    }
    $reader = New-Object IO.StreamReader($entry.Open())
    $jsonText = $reader.ReadToEnd()
    $main = $null
    $version = $null
    try {
      $manifest = $jsonText | ConvertFrom-Json -ErrorAction Stop
      if ($manifest.PSObject.Properties.Match('Main').Count -gt 0) {
        $main = [string]$manifest.Main
      }
      if ($manifest.PSObject.Properties.Match('Version').Count -gt 0) {
        $version = [string]$manifest.Version
      }
    } catch {
      # Fall back to regex parsing below.
    }

    if (-not $main) {
      $main = Get-HMDManifestFieldValue $jsonText "Main"
      if ($main -and $onLog) { & $onLog "Manifest field used: Main" "info" }
    }
    if (-not $main) {
      $main = Get-HMDManifestFieldValue $jsonText "Name"
      if ($main -and $onLog) { & $onLog "Manifest field used: Name (fallback)" "info" }
    }
    if (-not $version) {
      $version = Get-HMDManifestFieldValue $jsonText "Version"
    }

    return @{
      Name = $main
      Version = $version
    }
  } catch {
    if ($onLog) { & $onLog ("Failed to read manifest.json: {0}" -f $_.Exception.Message) "warn" }
    return $null
  } finally {
    if ($reader) { $reader.Dispose() }
    $zip.Dispose()
  }
}

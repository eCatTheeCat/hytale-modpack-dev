# HMD-DownloadOrchestrator.ps1
# Download orchestration helpers for HMD.

Set-StrictMode -Version Latest

function Get-HMDLatestCurseForgeUrl([string]$url) {
  $pattern = '^https?://www\.curseforge\.com/([^/]+)/mods/([^/]+)/download(?:/(\d+))?/?'
  $m = [regex]::Match($url, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) { return $null }
  return ("https://www.curseforge.com/{0}/mods/{1}/download/" -f $m.Groups[1].Value, $m.Groups[2].Value)
}

function Get-HMDUrlsToDownload {
  param(
    [string[]]$inputUrls,
    [ref]$completedRef,
    [object]$installIndex,
    [string]$destDir,
    [string]$installIndexFile,
    [scriptblock]$onLog,
    [scriptblock]$onStatus,
    [scriptblock]$onProgress,
    [scriptblock]$abortFlag
  )

  $out = @()
  foreach ($url in $inputUrls) {
    if ($abortFlag -and (& $abortFlag)) { break }
    $cfInfo = ConvertFrom-HMDCurseForgeUrl $url
    $skipEntry = $null
    $skipReason = $null

    if ($cfInfo) {
      if ($cfInfo.FileId) {
        if ($onLog) { & $onLog ("Parsed CurseForge URL: fileId={0}, mod={1}" -f $cfInfo.FileId, $cfInfo.ModSlug) "info" }
        $existingEntry = Find-HMDIndexEntries $installIndex { param($m) $m.fileId -eq $cfInfo.FileId } |
          Select-Object -First 1
        if ($existingEntry -and $existingEntry.fileName) {
          $existingPath = Join-Path $destDir $existingEntry.fileName
          if (Test-Path -LiteralPath $existingPath) {
            $skipEntry = $existingEntry
            $skipReason = "fileId"
          }
        }
      } else {
        if ($onLog) { & $onLog ("Parsed CurseForge URL: mod={0} (latest)" -f $cfInfo.ModSlug) "info" }
        $existingEntries = Find-HMDIndexEntries $installIndex { param($m) $m.modSlug -eq $cfInfo.ModSlug }
        $sawExistingFile = $false
        foreach ($entry in $existingEntries) {
          if (-not $entry.fileName) { continue }
          $existingPath = Join-Path $destDir $entry.fileName
          if (-not (Test-Path -LiteralPath $existingPath)) { continue }
          $sawExistingFile = $true
          $currentHash = Get-HMDFileHash $existingPath
          if (-not $currentHash) { continue }
          if ($entry.sha256 -and $entry.sha256 -eq $currentHash) {
            $skipEntry = $entry
            $skipReason = "latest-hash"
            break
          }
          if (-not $entry.sha256) {
            $entry.sha256 = $currentHash
            $installIndex = Update-HMDIndex $installIndex $entry
            if ($installIndexFile) { Set-HMDIndex $installIndexFile $installIndex }
            if ($onLog) { & $onLog ("Backfilled sha256 for {0}" -f $entry.fileName) "info" }
            $skipEntry = $entry
            $skipReason = "latest-backfill"
            break
          }
        }
        if (-not $skipEntry -and $sawExistingFile) {
          if ($onLog) { & $onLog ("Existing mod found for {0}, but hash mismatch; will re-download." -f $cfInfo.ModSlug) "warn" }
        }
      }
    } else {
      if ($onLog) { & $onLog "URL not recognized as CurseForge format." "warn" }
    }

    if ($skipEntry) {
      if ($onStatus) { & $onStatus ("Already installed: {0}" -f $skipEntry.fileName) }
      if ($skipReason -eq "fileId") {
        if ($onLog) { & $onLog ("Skipping already installed fileId {0}: {1}" -f $cfInfo.FileId, $skipEntry.fileName) "info" }
      } else {
        if ($onLog) { & $onLog ("Skipping already installed latest for mod {0}: {1}" -f $cfInfo.ModSlug, $skipEntry.fileName) "info" }
      }
      $completedRef.Value++
      if ($onProgress) { & $onProgress $completedRef.Value }
      continue
    }

    $out += $url
  }

  return [pscustomobject]@{
    Urls = @($out)
    InstallIndex = $installIndex
  }
}

function Invoke-HMDDownloadResults {
  param(
    [object[]]$results,
    [object]$installIndex,
    [string]$destDir,
    [string]$installIndexFile,
    [scriptblock]$onLog,
    [scriptblock]$abortFlag
  )

  $failed = @()
  foreach ($result in $results) {
    if ($abortFlag -and (& $abortFlag)) { break }
    if ($result.status -ne "success" -or -not $result.destPath) {
      if ($onLog) { & $onLog ("Download failed for {0} ({1})" -f $result.url, $result.reason) "warn" }
      $failed += $result
      continue
    }

    $dest = $result.destPath
    if ($onLog) { & $onLog ("Reading manifest: {0}" -f $dest) "info" }
    $manifestInfo = Get-HMDModManifestInfo -filePath $dest -onLog $onLog
    $modName = $null
    $modVersion = $null
    if ($manifestInfo) {
      $modName = $manifestInfo.Name
      $modVersion = $manifestInfo.Version
      if ($onLog) { & $onLog ("Manifest: name={0}, version={1}" -f $modName, $modVersion) "info" }
    } else {
      if ($onLog) { & $onLog "Manifest info missing; recording file without name/version." "warn" }
    }

    $cfInfo = ConvertFrom-HMDCurseForgeUrl $result.url
    $fileId = if ($cfInfo) { $cfInfo.FileId } else { $null }
    $game = if ($cfInfo) { $cfInfo.Game } else { $null }
    $modSlug = if ($cfInfo) { $cfInfo.ModSlug } else { $null }
    $fileName = [IO.Path]::GetFileName($dest)
    $sha256 = Get-HMDFileHash $dest

    if ($modName -and $modVersion) {
      $oldEntries = Find-HMDIndexEntries $installIndex { param($m) $m.modName -eq $modName -and $m.version -ne $modVersion }
      foreach ($old in $oldEntries) {
        if ($old.fileName) {
          $oldPath = Join-Path $destDir $old.fileName
          if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Force
            if ($onLog) { & $onLog ("Removed old version: {0}" -f $old.fileName) "info" }
          }
        }
      }
      $installIndex = Remove-HMDIndexEntries $installIndex { param($m) $m.modName -eq $modName -and $m.version -ne $modVersion }
    }

    $entry = [ordered]@{
      fileId = $fileId
      modName = $modName
      version = $modVersion
      fileName = $fileName
      url = $result.url
      sourceType = if ($fileId) { "fileId" } else { "latest" }
      sourceUrl = $result.url
      game = $game
      modSlug = $modSlug
      sha256 = $sha256
      installedAt = (Get-Date).ToString("s")
    }
    $installIndex = Update-HMDIndex $installIndex $entry
    if ($installIndexFile) { Set-HMDIndex $installIndexFile $installIndex }
    if ($onLog) { & $onLog ("Updated install index: {0}" -f $installIndexFile) "success" }
  }

  return [pscustomobject]@{
    Failed = @($failed)
    InstallIndex = $installIndex
  }
}

# HMD-Downloader.ps1
# Browser download workflow helpers for HMD.

Set-StrictMode -Version Latest

function ConvertFrom-HMDCurseForgeUrl([string]$url) {
  $pattern = '^https?://www\.curseforge\.com/([^/]+)/mods/([^/]+)/download(?:/(\d+))?/?'
  $m = [regex]::Match($url, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) { return $null }
  $fileId = if ($m.Groups[3].Success -and $m.Groups[3].Value) { $m.Groups[3].Value } else { $null }
  return [pscustomobject]@{
    Game = $m.Groups[1].Value
    ModSlug = $m.Groups[2].Value
    FileId = $fileId
  }
}

function Get-HMDDownloadSnapshot([string]$downloadDir) {
  Get-ChildItem -LiteralPath $downloadDir -File |
    Select-Object FullName, Name, Length, LastWriteTime
}

function Test-HMDFileUnlocked([string]$path, [int]$timeoutSec, [int]$pollMs, [scriptblock]$onLog, [scriptblock]$abortFlag) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
    if ($abortFlag -and (& $abortFlag)) { return $false }
    try {
      $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $fs.Close()
      return $true
    } catch {
      Start-Sleep -Milliseconds $pollMs
    }
  }
  if ($onLog) { & $onLog ("File still locked after timeout: {0}" -f $path) "warn" }
  return $false
}

function Get-HMDNewCompletedDownload {
  param(
    [object[]]$beforeSnapshot,
    [string]$downloadDir,
    [int]$timeoutSec,
    [int]$noFileTimeoutSec,
    [int]$pollMs,
    [int]$minStableAgeMs,
    [scriptblock]$onLog,
    [scriptblock]$abortFlag
  )

  $before = @{}
  foreach ($f in $beforeSnapshot) { $before[$f.FullName] = $true }
  $loggedCandidates = @{}
  $loggedZero = @{}
  $sawAnyNew = $false

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
    Start-Sleep -Milliseconds $pollMs
    if ($abortFlag -and (& $abortFlag)) { return [pscustomobject]@{ Path = $null; Reason = "aborted" } }

    $current = Get-ChildItem -LiteralPath $downloadDir -File
    $newFiles = $current | Where-Object { -not $before.ContainsKey($_.FullName) }
    if (@($newFiles).Count -gt 0) { $sawAnyNew = $true }
    if (-not $sawAnyNew -and $sw.Elapsed.TotalSeconds -ge $noFileTimeoutSec) {
      if ($onLog) { & $onLog ("No download detected within {0}s; skipping." -f $noFileTimeoutSec) "warn" }
      return [pscustomobject]@{ Path = $null; Reason = "no-file-timeout" }
    }

    foreach ($f in $newFiles) {
      if ($f.Extension -in @(".part", ".crdownload", ".tmp", ".partial", ".download")) { continue }
      if ($f.Length -le 0) {
        if (-not $loggedZero.ContainsKey($f.FullName)) {
          if ($onLog) { & $onLog ("Detected zero-byte file, waiting: {0}" -f $f.FullName) "warn" }
          $loggedZero[$f.FullName] = $true
        }
        continue
      }
      if (-not $loggedCandidates.ContainsKey($f.FullName)) {
        if ($onLog) { & $onLog ("Detected new file: {0}" -f $f.FullName) "info" }
        $loggedCandidates[$f.FullName] = $true
      }

      $partPath = $f.FullName + ".part"
      $hasPart = Test-Path -LiteralPath $partPath
      if (-not $hasPart) {
        $stable = $true
        $prevSize = $null
        for ($i = 0; $i -lt 10; $i++) {
          $fi = Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue
          if (-not $fi) { $stable = $false; break }
          if ($i -eq 0) {
            $prevSize = $fi.Length
          } elseif ($fi.Length -ne $prevSize) {
            $stable = $false
            break
          }
          Start-Sleep -Milliseconds $pollMs
          if ($abortFlag -and (& $abortFlag)) { return [pscustomobject]@{ Path = $null; Reason = "aborted" } }
        }
        if ($stable) {
          if ($onLog) { & $onLog ("Size stable: {0}" -f $f.FullName) "info" }
          $ageMs = ((Get-Date) - $f.LastWriteTime).TotalMilliseconds
          if ($ageMs -lt $minStableAgeMs) { continue }
          $remaining = [Math]::Max(1, [int][Math]::Ceiling($timeoutSec - $sw.Elapsed.TotalSeconds))
          if (Test-HMDFileUnlocked $f.FullName $remaining $pollMs $onLog $abortFlag) {
            return [pscustomobject]@{ Path = $f.FullName; Reason = "ok" }
          }
        }
      }
    }
  }

  return [pscustomobject]@{ Path = $null; Reason = "timeout" }
}

function Open-HMDBrowserUrl([string]$url, [hashtable]$options) {
  if ([string]::IsNullOrWhiteSpace($url)) {
    if ($options.OnLog) { & $options.OnLog "Skipped empty URL." "warn" }
    return
  }
  $browser = $options.BrowserState
  if ($browser -and $browser.Info -and (Test-Path -LiteralPath $browser.Info.Exe)) {
    if ($browser.Name -ieq "firefox") {
      if (-not $browser.SessionOpened) {
        Start-Process -FilePath $browser.Info.Exe -ArgumentList @("-new-window", $url) | Out-Null
        $browser.SessionOpened = $true
      } else {
        Start-Process -FilePath $browser.Info.Exe -ArgumentList @("-new-tab", $url) | Out-Null
      }
    } else {
      $prefixArgs = if ($browser.SessionOpened) { $null } else { $browser.InstanceArgs }
      $launchArgs = $options.BuildBrowserArguments.Invoke($browser.Info.Args, $url, $prefixArgs)
      if ([string]::IsNullOrWhiteSpace($launchArgs)) {
        if ($options.OnLog) { & $options.OnLog "Browser args empty; skipping open." "warn" }
        return
      }
      Start-Process -FilePath $browser.Info.Exe -ArgumentList $launchArgs | Out-Null
      $browser.SessionOpened = $true
    }
  } else {
    Start-Process $url | Out-Null
  }
}

function Invoke-HMDDownloads([string[]]$urls, [hashtable]$options) {
  $downloadDir = $options.DownloadDir
  $destDir = $options.DestDir
  $pollMs = $options.PollMs
  $timeoutSec = $options.TimeoutSec
  $noFileTimeoutSec = $options.NoFileTimeoutSec
  $minStableAgeMs = $options.MinStableAgeMs
  $windowDelayMs = if ($options.ContainsKey("BrowserWindowDelayMs")) { [int]$options.BrowserWindowDelayMs } else { 0 }
  $onLog = $options.OnLog
  $onProgress = $options.OnProgress
  $abortFlag = $options.AbortFlag

  $results = @()
  $completed = 0

  foreach ($url in $urls) {
    if ($abortFlag -and (& $abortFlag)) { break }

    if ($onLog) { & $onLog ("Opening: {0}" -f $url) "info" }
    $before = Get-HMDDownloadSnapshot $downloadDir
    Open-HMDBrowserUrl $url $options
    if ($windowDelayMs -gt 0) { Start-Sleep -Milliseconds $windowDelayMs }

    if ($onLog) { & $onLog "Waiting for download..." "info" }
    $downloadResult = Get-HMDNewCompletedDownload -beforeSnapshot $before -downloadDir $downloadDir `
      -timeoutSec $timeoutSec -noFileTimeoutSec $noFileTimeoutSec -pollMs $pollMs -minStableAgeMs $minStableAgeMs `
      -onLog $onLog -abortFlag $abortFlag

    if ($downloadResult.Path) {
      $name = [IO.Path]::GetFileName($downloadResult.Path)
      $dest = Join-Path $destDir $name
      if (Test-Path -LiteralPath $dest) {
        $base = [IO.Path]::GetFileNameWithoutExtension($name)
        $ext  = [IO.Path]::GetExtension($name)
        $i = 1
        do {
          $dest = Join-Path $destDir ("{0} ({1}){2}" -f $base, $i, $ext)
          $i++
        } while (Test-Path -LiteralPath $dest)
      }

      Move-Item -LiteralPath $downloadResult.Path -Destination $dest
      if ($onLog) { & $onLog ("Moved to: {0}" -f $dest) "info" }
      $results += [pscustomobject]@{ url = $url; status = "success"; reason = $downloadResult.Reason; downloadedPath = $downloadResult.Path; destPath = $dest }
    } else {
      if ($onLog) { & $onLog ("Download failed: {0}" -f $downloadResult.Reason) "warn" }
      $results += [pscustomobject]@{ url = $url; status = "failed"; reason = $downloadResult.Reason; downloadedPath = $null; destPath = $null }
    }

    $completed++
    if ($onProgress) { & $onProgress $completed }
  }

  return $results
}

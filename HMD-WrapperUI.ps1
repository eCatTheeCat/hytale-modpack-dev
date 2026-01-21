# HMD-WrapperUI.ps1
# Main UI wrapper for HMD installer.

# Ensure WinForms runs in STA (pwsh defaults to MTA, which can prevent UI from showing).
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  $scriptPath = $PSCommandPath
  if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
  $pwsh = Join-Path $PSHOME "pwsh.exe"
  $exe = if (Test-Path -LiteralPath $pwsh) { $pwsh } else { Join-Path $PSHOME "powershell.exe" }
  $procArgs = @()
  if ($exe -like "*powershell.exe") {
    $procArgs += "-ExecutionPolicy"
    $procArgs += "Bypass"
  }
  $procArgs += "-Sta"
  $procArgs += "-File"
  $procArgs += "`"$scriptPath`""
  Start-Process -FilePath $exe -ArgumentList $procArgs -WorkingDirectory $PSScriptRoot | Out-Null
  exit
}

$DownloadDir = Join-Path $env:USERPROFILE "Downloads"

$PollMs      = 50
$TimeoutSec  = 180
$MinStableAgeMs = 1000
$NoFileTimeoutSec = 10

try {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
  $isPwsh = ($PSVersionTable.PSEdition -eq 'Core') -or ($PSVersionTable.PSVersion.Major -ge 6)
  if ($isPwsh) {
    Write-Host "WinForms failed to load in PowerShell 7. Install the .NET Desktop Runtime or run this script in Windows PowerShell 5.1."
    exit 1
  }
  throw
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

. (Join-Path $PSScriptRoot "HMD-IndexHandler.ps1")
. (Join-Path $PSScriptRoot "HMD-Downloader.ps1")
. (Join-Path $PSScriptRoot "HMD-Browser.ps1")
. (Join-Path $PSScriptRoot "HMD-SaveHandler.ps1")
. (Join-Path $PSScriptRoot "HMD-Ui.ps1")

$script:Abort = $false
$script:LogBuffer = New-Object System.Collections.Generic.List[object]

function Add-LogBuffer([string]$text, [string]$level = "info") {
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $script:LogBuffer.Add([pscustomobject]@{
      Text = "$stamp $text"
      Level = $level
    })
}

Add-LogBuffer "Script started."

function ConvertFrom-CurseForgeUrl([string]$url) {
  return ConvertFrom-HMDCurseForgeUrl $url
}

function Get-LatestCurseForgeUrl([string]$url) {
  $pattern = '^https?://www\.curseforge\.com/([^/]+)/mods/([^/]+)/download(?:/(\d+))?/?'
  $m = [regex]::Match($url, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) { return $null }
  return ("https://www.curseforge.com/{0}/mods/{1}/download/" -f $m.Groups[1].Value, $m.Groups[2].Value)
}

function Get-ManifestFieldValue([string]$text, [string]$key) {
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

function Get-ModManifestInfo([string]$filePath) {
  try {
    $zip = [IO.Compression.ZipFile]::OpenRead($filePath)
  } catch {
    Add-Log ("Not a zip or cannot open: {0}" -f $filePath) "warn"
    return $null
  }

  $entry = $null
  $reader = $null
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -match '(^|/|\\)manifest\.json$' } | Select-Object -First 1
    if (-not $entry) {
      Add-Log "manifest.json not found in mod file." "warn"
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
      $main = Get-ManifestFieldValue $jsonText "Main"
      if ($main) { Add-Log "Manifest field used: Main" }
    }
    if (-not $main) {
      $main = Get-ManifestFieldValue $jsonText "Name"
      if ($main) { Add-Log "Manifest field used: Name (fallback)" }
    }
    if (-not $version) {
      $version = Get-ManifestFieldValue $jsonText "Version"
    }

    return @{
      Name = $main
      Version = $version
    }
  } catch {
    Add-Log ("Failed to read manifest.json: {0}" -f $_.Exception.Message) "warn"
    return $null
  } finally {
    if ($reader) { $reader.Dispose() }
    $zip.Dispose()
  }
}

$UserDataDir = Get-HMDHytaleUserDataDir { param($msg, $level) Add-LogBuffer $msg $level }
if (-not $UserDataDir) { throw "Hytale install location not provided." }
Add-LogBuffer ("Using UserData folder: {0}" -f $UserDataDir)

$LinksFile   = Join-Path $PSScriptRoot "modDownloadLinks.txt"
$DestDir     = Join-Path $UserDataDir "Mods"
$InstallIndexFile = Join-Path $UserDataDir "modInstallIndex.json"
Add-LogBuffer ("Links file: {0}" -f $LinksFile)
Add-LogBuffer ("Mods folder: {0}" -f $DestDir)
Add-LogBuffer ("Install index: {0}" -f $InstallIndexFile)

$script:LinksFileMissing = $false
if (!(Test-Path $LinksFile)) {
  $script:LinksFileMissing = $true
  Add-LogBuffer ("Missing links file: {0}" -f $LinksFile) "error"
}
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Add-LogBuffer ("Ensured Mods folder exists: {0}" -f $DestDir)

$script:InstallIndex = Get-HMDIndex $InstallIndexFile
Add-LogBuffer ("Loaded install entries: {0}" -f $script:InstallIndex.mods.Count)

$SavesDir = Join-Path $UserDataDir "Saves"
$SaveName = "AMMAP"
$ConfigSource = Join-Path $PSScriptRoot "AMMAP_CONFIG"

$script:BrowserState = Get-HMDBrowserState
$script:BrowserInfo = $script:BrowserState.Info
$script:BrowserName = $script:BrowserState.Name
$script:BrowserInstanceArgs = $script:BrowserState.InstanceArgs
if ($script:BrowserInfo) {
  Add-LogBuffer ("Default browser: {0}" -f $script:BrowserName)
  if ($script:BrowserInstanceArgs) {
    Add-LogBuffer ("Launching in new window: {0}" -f $script:BrowserInstanceArgs)
  } else {
    Add-LogBuffer "No new-window args for this browser; using default launch."
  }
  if ($script:BrowserName -ieq "firefox") {
    Add-LogBuffer "Will use one Firefox window and open tabs for each download."
    Add-LogBuffer "Will attempt to close the Firefox download window when finished."
  } else {
    Add-LogBuffer "Will use one window when possible; tabs are best-effort."
  }
} else {
  Add-LogBuffer "Default browser detection failed; using shell open." "warn"
  Add-LogBuffer "Browser windows will be left open to avoid affecting existing sessions."
}

$urls = if ($script:LinksFileMissing) {
  @()
} else {
  Get-Content -LiteralPath $LinksFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }
}

$total = $urls.Count
$script:Ui = New-HMDUi -totalCount $total -logBuffer $script:LogBuffer -onAbort {
  param($ui)
  if (-not $script:Abort) {
    $script:Abort = $true
    Set-HMDStatus $ui "Abort requested..."
    Add-HMDLog $ui "Abort requested by user."
  }
}
$script:MainForm = $script:Ui.Form

function Add-Log([string]$text, [string]$level = "info") {
  Add-HMDLog $script:Ui $text $level
}

function Set-Status([string]$text) {
  Set-HMDStatus $script:Ui $text
}

function Set-Progress([int]$value) {
  Set-HMDProgress $script:Ui $value
}

function Get-UrlsToDownload([string[]]$inputUrls, [ref]$completedRef) {
  $out = @()
  foreach ($url in $inputUrls) {
    if ($script:Abort) { break }
    $cfInfo = ConvertFrom-CurseForgeUrl $url
    $skipEntry = $null
    $skipReason = $null

    if ($cfInfo) {
      if ($cfInfo.FileId) {
        Add-Log ("Parsed CurseForge URL: fileId={0}, mod={1}" -f $cfInfo.FileId, $cfInfo.ModSlug)
        $existingEntry = Find-HMDIndexEntries $script:InstallIndex { param($m) $m.fileId -eq $cfInfo.FileId } |
          Select-Object -First 1
        if ($existingEntry -and $existingEntry.fileName) {
          $existingPath = Join-Path $DestDir $existingEntry.fileName
          if (Test-Path -LiteralPath $existingPath) {
            $skipEntry = $existingEntry
            $skipReason = "fileId"
          }
        }
      } else {
        Add-Log ("Parsed CurseForge URL: mod={0} (latest)" -f $cfInfo.ModSlug)
        $existingEntries = Find-HMDIndexEntries $script:InstallIndex { param($m) $m.modSlug -eq $cfInfo.ModSlug }
        $sawExistingFile = $false
        foreach ($entry in $existingEntries) {
          if (-not $entry.fileName) { continue }
          $existingPath = Join-Path $DestDir $entry.fileName
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
            $script:InstallIndex = Update-HMDIndex $script:InstallIndex $entry
            Set-HMDIndex $InstallIndexFile $script:InstallIndex
            Add-Log ("Backfilled sha256 for {0}" -f $entry.fileName)
            $skipEntry = $entry
            $skipReason = "latest-backfill"
            break
          }
        }
        if (-not $skipEntry -and $sawExistingFile) {
          Add-Log ("Existing mod found for {0}, but hash mismatch; will re-download." -f $cfInfo.ModSlug) "warn"
        }
      }
    } else {
      Add-Log "URL not recognized as CurseForge format."
    }

    if ($skipEntry) {
      Set-Status ("Already installed: {0}" -f $skipEntry.fileName)
      if ($skipReason -eq "fileId") {
        Add-Log ("Skipping already installed fileId {0}: {1}" -f $cfInfo.FileId, $skipEntry.fileName)
      } else {
        Add-Log ("Skipping already installed latest for mod {0}: {1}" -f $cfInfo.ModSlug, $skipEntry.fileName)
      }
      $completedRef.Value++
      Set-Progress $completedRef.Value
      continue
    }

    $out += $url
  }
  return ,$out
}

function Invoke-HMDDownloadResults([object[]]$results) {
  $failed = @()
  foreach ($result in $results) {
    if ($script:Abort) { break }
    if ($result.status -ne "success" -or -not $result.destPath) {
      Add-Log ("Download failed for {0} ({1})" -f $result.url, $result.reason) "warn"
      $failed += $result
      continue
    }

    $dest = $result.destPath
    Add-Log ("Reading manifest: {0}" -f $dest)
    $manifestInfo = Get-ModManifestInfo $dest
    $modName = $null
    $modVersion = $null
    if ($manifestInfo) {
      $modName = $manifestInfo.Name
      $modVersion = $manifestInfo.Version
      Add-Log ("Manifest: name={0}, version={1}" -f $modName, $modVersion)
    } else {
      Add-Log "Manifest info missing; recording file without name/version." "warn"
    }

    $cfInfo = ConvertFrom-CurseForgeUrl $result.url
    $fileId = if ($cfInfo) { $cfInfo.FileId } else { $null }
    $game = if ($cfInfo) { $cfInfo.Game } else { $null }
    $modSlug = if ($cfInfo) { $cfInfo.ModSlug } else { $null }
    $fileName = [IO.Path]::GetFileName($dest)
    $sha256 = Get-HMDFileHash $dest

    if ($modName -and $modVersion) {
      $oldEntries = Find-HMDIndexEntries $script:InstallIndex { param($m) $m.modName -eq $modName -and $m.version -ne $modVersion }
      foreach ($old in $oldEntries) {
        if ($old.fileName) {
          $oldPath = Join-Path $DestDir $old.fileName
          if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Force
            Add-Log ("Removed old version: {0}" -f $old.fileName)
          }
        }
      }
      $script:InstallIndex = Remove-HMDIndexEntries $script:InstallIndex { param($m) $m.modName -eq $modName -and $m.version -ne $modVersion }
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
    $script:InstallIndex = Update-HMDIndex $script:InstallIndex $entry
    Set-HMDIndex $InstallIndexFile $script:InstallIndex
    Add-Log ("Updated install index: {0}" -f $InstallIndexFile) "success"
  }
  return ,$failed
}

$script:Ui.Form.Add_Shown({
  if ($total -eq 0) {
    if ($script:LinksFileMissing) {
      Set-Status "Missing modDownloadLinks.txt."
      Add-Log "Missing modDownloadLinks.txt." "error"
    } else {
      Set-Status "No URLs found in modDownloadLinks.txt."
      Add-Log "No URLs found in modDownloadLinks.txt."
    }
    return
  }

  $completed = 0
  $urlsToDownload = Get-UrlsToDownload $urls ([ref]$completed)

  $downloadOptions = @{
    DownloadDir = $DownloadDir
    DestDir = $DestDir
    PollMs = $PollMs
    TimeoutSec = $TimeoutSec
    NoFileTimeoutSec = $NoFileTimeoutSec
    MinStableAgeMs = $MinStableAgeMs
    BrowserState = $script:BrowserState
    BuildBrowserArguments = { param($browserArgs, $url, $prefixArgs) New-HMDBrowserArguments $browserArgs $url $prefixArgs }
    OnLog = { param($msg, $level)
      Add-Log $msg $level
      if ($msg -like "Opening:*") { Set-Status $msg }
      elseif ($msg -like "Waiting for download*") { Set-Status "Waiting for download..." }
      elseif ($msg -like "Moved to:*") { Set-Status $msg }
    }
    OnProgress = { param($count) Set-Progress ($completed + $count) }
    AbortFlag = { return $script:Abort }
  }

  $downloadResults = @()
  if ($urlsToDownload.Count -gt 0 -and -not $script:Abort) {
    $downloadResults = Invoke-HMDDownloads $urlsToDownload $downloadOptions
  }

  $completed += $downloadResults.Count
  Set-Progress $completed

  $failedDownloads = Invoke-HMDDownloadResults $downloadResults

  if ($failedDownloads.Count -gt 0 -and -not $script:Abort) {
    $owner = $script:MainForm
    if ($owner) {
      $owner.TopMost = $true
      $owner.Activate()
    }
    $retryPrompt = "Some downloads failed.`n`nRetry using latest CurseForge links?`nYes = Retry failed mods`nNo = Skip"
    $retryChoice = if ($owner) {
      [System.Windows.Forms.MessageBox]::Show(
        $owner,
        $retryPrompt,
        "Retry Failed Downloads",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
      )
    } else {
      [System.Windows.Forms.MessageBox]::Show(
        $retryPrompt,
        "Retry Failed Downloads",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
      )
    }
    if ($owner) { $owner.TopMost = $false }

    if ($retryChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
      $retryUrls = @()
      foreach ($fail in $failedDownloads) {
        $latestUrl = Get-LatestCurseForgeUrl $fail.url
        if ($latestUrl) {
          $retryUrls += $latestUrl
        } else {
          Add-Log ("Retry skipped; not a CurseForge URL: {0}" -f $fail.url) "warn"
        }
      }
      $retryUrls = $retryUrls | Sort-Object -Unique

      if ($retryUrls.Count -gt 0) {
        Add-Log ("Retrying failed downloads using latest links: {0}" -f $retryUrls.Count) "warn"
        Set-Status ("Retrying {0} downloads..." -f $retryUrls.Count)
        $script:Ui.ProgressMax = [Math]::Max(1, $script:Ui.ProgressMax + $retryUrls.Count)
        Set-Progress $completed

        $retryUrlsToDownload = Get-UrlsToDownload $retryUrls ([ref]$completed)
        if ($retryUrlsToDownload.Count -gt 0 -and -not $script:Abort) {
          $retryResults = Invoke-HMDDownloads $retryUrlsToDownload $downloadOptions
          $completed += $retryResults.Count
          Set-Progress $completed
          $retryFailed = Invoke-HMDDownloadResults $retryResults
          $retrySuccessCount = @($retryResults | Where-Object { $_.status -eq "success" }).Count
          $retryFailCount = $retryFailed.Count
          $retryLevel = if ($retryFailCount -eq 0) { "success" } else { "warn" }
          Add-Log ("Retry results: {0} succeeded, {1} failed." -f $retrySuccessCount, $retryFailCount) $retryLevel
          if ($retryFailed.Count -gt 0) {
            Add-Log ("Some downloads still failed after retry: {0}" -f $retryFailed.Count) "warn"
          }
        } else {
          Add-Log "No retry downloads needed after filtering." "warn"
        }
      } else {
        Add-Log "No retryable CurseForge URLs found." "warn"
      }
    } else {
      Add-Log "Retry skipped by user." "warn"
    }
  }

  if ($script:Abort) {
    Set-Status "Aborted."
    Add-Log "Aborted." "warn"
    return
  }

  Set-Status "Done."
  Add-Log "Done." "success"
  if ($script:BrowserName -ieq "firefox" -and $script:BrowserState.SessionOpened) {
    Add-Log "Closing Firefox download window..."
    Stop-HMDFirefoxWindow
  }
  Add-Log "Updating AMMAP save..."
  Set-HMDSave -savesDir $SavesDir -saveName $SaveName -configSource $ConfigSource -owner $script:MainForm -onLog ${function:Add-Log}
  Write-Host "`nDone."
})

[System.Windows.Forms.Application]::Run($script:Ui.Form)


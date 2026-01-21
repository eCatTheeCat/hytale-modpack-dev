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
. (Join-Path $PSScriptRoot "HMD-DownloadOrchestrator.ps1")

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
  $urlResult = Get-HMDUrlsToDownload -inputUrls $urls -completedRef ([ref]$completed) -installIndex $script:InstallIndex `
    -destDir $DestDir -installIndexFile $InstallIndexFile -onLog ${function:Add-Log} -onStatus ${function:Set-Status} `
    -onProgress ${function:Set-Progress} -abortFlag { return $script:Abort }
  $script:InstallIndex = $urlResult.InstallIndex
  $urlsToDownload = $urlResult.Urls

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
  if (@($urlsToDownload).Count -gt 0 -and -not $script:Abort) {
    $downloadResults = Invoke-HMDDownloads $urlsToDownload $downloadOptions
  }

  $completed += @($downloadResults).Count
  Set-Progress $completed

  $processResult = Invoke-HMDDownloadResults -results $downloadResults -installIndex $script:InstallIndex -destDir $DestDir `
    -installIndexFile $InstallIndexFile -onLog ${function:Add-Log} -abortFlag { return $script:Abort }
  $script:InstallIndex = $processResult.InstallIndex
  $failedDownloads = $processResult.Failed

  if (@($failedDownloads).Count -gt 0 -and -not $script:Abort) {
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
        $latestUrl = Get-HMDLatestCurseForgeUrl $fail.url
        if ($latestUrl) {
          $retryUrls += $latestUrl
        } else {
          Add-Log ("Retry skipped; not a CurseForge URL: {0}" -f $fail.url) "warn"
        }
      }
      $retryUrls = $retryUrls | Sort-Object -Unique

      if (@($retryUrls).Count -gt 0) {
        $retryUrlCount = @($retryUrls).Count
        Add-Log ("Retrying failed downloads using latest links: {0}" -f $retryUrlCount) "warn"
        Set-Status ("Retrying {0} downloads..." -f $retryUrlCount)
        $script:Ui.ProgressMax = [Math]::Max(1, $script:Ui.ProgressMax + $retryUrlCount)
        Set-Progress $completed

        $retryUrlResult = Get-HMDUrlsToDownload -inputUrls $retryUrls -completedRef ([ref]$completed) -installIndex $script:InstallIndex `
          -destDir $DestDir -installIndexFile $InstallIndexFile -onLog ${function:Add-Log} -onStatus ${function:Set-Status} `
          -onProgress ${function:Set-Progress} -abortFlag { return $script:Abort }
        $script:InstallIndex = $retryUrlResult.InstallIndex
        $retryUrlsToDownload = $retryUrlResult.Urls
        if (@($retryUrlsToDownload).Count -gt 0 -and -not $script:Abort) {
          $retryResults = Invoke-HMDDownloads $retryUrlsToDownload $downloadOptions
          $completed += @($retryResults).Count
          Set-Progress $completed
          $retryProcess = Invoke-HMDDownloadResults -results $retryResults -installIndex $script:InstallIndex -destDir $DestDir `
            -installIndexFile $InstallIndexFile -onLog ${function:Add-Log} -abortFlag { return $script:Abort }
          $script:InstallIndex = $retryProcess.InstallIndex
          $retryFailed = $retryProcess.Failed
          $retrySuccessCount = @($retryResults | Where-Object { $_.status -eq "success" }).Count
          $retryFailCount = @($retryFailed).Count
          $retryLevel = if ($retryFailCount -eq 0) { "success" } else { "warn" }
          Add-Log ("Retry results: {0} succeeded, {1} failed." -f $retrySuccessCount, $retryFailCount) $retryLevel
          if (@($retryFailed).Count -gt 0) {
            Add-Log ("Some downloads still failed after retry: {0}" -f @($retryFailed).Count) "warn"
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


# Download-Mods.ps1
# Reads URLs from modDownloadLinks.txt, opens each in browser, waits for a new download to complete, then moves it.

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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Abort = $false
$script:LogBuffer = New-Object System.Collections.Generic.List[string]

function Add-LogBuffer([string]$text) {
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $script:LogBuffer.Add("$stamp $text")
}

Add-LogBuffer "Script started."

function Split-CommandLine([string]$command) {
  if ([string]::IsNullOrWhiteSpace($command)) { return $null }
  $cmd = $command.Trim()
  if ($cmd.StartsWith('"')) {
    $end = $cmd.IndexOf('"', 1)
    if ($end -lt 1) { return $null }
    $exe = $cmd.Substring(1, $end - 1)
    $cmdArgs = $cmd.Substring($end + 1).Trim()
  } else {
    $space = $cmd.IndexOf(' ')
    if ($space -lt 0) {
      $exe = $cmd
      $cmdArgs = ""
    } else {
      $exe = $cmd.Substring(0, $space)
      $cmdArgs = $cmd.Substring($space + 1).Trim()
    }
  }
  return @{ Exe = $exe; Args = $cmdArgs }
}

function New-BrowserArguments([string]$browserArgs, [string]$url, [string]$prefixArgs) {
  $quotedUrl = '"' + $url + '"'
  if ([string]::IsNullOrWhiteSpace($browserArgs)) {
    if ([string]::IsNullOrWhiteSpace($prefixArgs)) { return $quotedUrl }
    return ($prefixArgs + " " + $quotedUrl).Trim()
  }
  if ($browserArgs -match '%1|%l|%u') {
    $out = $browserArgs -replace '%1', $quotedUrl -replace '%l', $quotedUrl -replace '%u', $quotedUrl
    if ([string]::IsNullOrWhiteSpace($prefixArgs)) { return $out.Trim() }
    return ($prefixArgs + " " + $out).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($prefixArgs)) { return ($browserArgs + " " + $quotedUrl).Trim() }
  return ($prefixArgs + " " + $browserArgs + " " + $quotedUrl).Trim()
}

function Get-BrowserInstanceArgs([string]$exePath) {
  if ([string]::IsNullOrWhiteSpace($exePath)) { return $null }
  $exeName = [IO.Path]::GetFileNameWithoutExtension($exePath).ToLowerInvariant()
  switch -Regex ($exeName) {
    '^firefox$' { return "-new-window" }
    '^(chrome|msedge|brave|vivaldi|opera)$' { return "--new-window" }
    default { return $null }
  }
}

function Get-DefaultBrowserInfo {
  $progId = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -ErrorAction SilentlyContinue).ProgId
  if (-not $progId) { return $null }
  $cmdKey = "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command"
  $cmd = $null
  try {
    $cmd = (Get-Item -Path $cmdKey -ErrorAction Stop).GetValue('')
  } catch {
    return $null
  }
  if (-not $cmd) { return $null }
  $parsed = Split-CommandLine $cmd
  if (-not $parsed) { return $null }
  if ([IO.Path]::GetFileName($parsed.Exe) -ieq "rundll32.exe") { return $null }
  return $parsed
}

function Open-UrlInDefaultBrowser([string]$url) {
  if ($script:BrowserInfo -and (Test-Path -LiteralPath $script:BrowserInfo.Exe)) {
    $browserLaunchArgs = New-BrowserArguments $script:BrowserInfo.Args $url $script:BrowserInstanceArgs
    Start-Process -FilePath $script:BrowserInfo.Exe -ArgumentList $browserLaunchArgs | Out-Null
  } else {
    Start-Process $url | Out-Null
  }
}

function ConvertFrom-CurseForgeUrl([string]$url) {
  $pattern = 'https?://www\.curseforge\.com/([^/]+)/mods/([^/]+)/download/(\d+)'
  $m = [regex]::Match($url, $pattern)
  if (-not $m.Success) { return $null }
  return @{
    Game = $m.Groups[1].Value
    ModSlug = $m.Groups[2].Value
    FileId = $m.Groups[3].Value
  }
}

function Get-InstallIndex([string]$path) {
  if (!(Test-Path -LiteralPath $path)) {
    return @{ mods = @() }
  }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $data = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Add-LogBuffer ("Failed to read install index, starting fresh: {0}" -f $_.Exception.Message)
    return @{ mods = @() }
  }
  if ($null -eq $data.mods) {
    $data | Add-Member -NotePropertyName mods -NotePropertyValue @()
  }
  $data.mods = @($data.mods)
  return $data
}

function Set-InstallIndex([string]$path, $data) {
  $json = $data | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-ModManifestInfo([string]$filePath) {
  try {
    $zip = [IO.Compression.ZipFile]::OpenRead($filePath)
  } catch {
    Add-Log ("Not a zip or cannot open: {0}" -f $filePath)
    return $null
  }

  $entry = $null
  $reader = $null
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -match '(^|/|\\)manifest\.json$' } | Select-Object -First 1
    if (-not $entry) {
      Add-Log "manifest.json not found in mod file."
      return $null
    }
    $reader = New-Object IO.StreamReader($entry.Open())
    $jsonText = $reader.ReadToEnd()
    $manifest = $jsonText | ConvertFrom-Json -ErrorAction Stop
    return @{
      Name = $manifest.Main
      Version = $manifest.Version
    }
  } catch {
    Add-Log ("Failed to read manifest.json: {0}" -f $_.Exception.Message)
    return $null
  } finally {
    if ($reader) { $reader.Dispose() }
    $zip.Dispose()
  }
}

function Get-HytaleUserDataDir {
  $defaultRoot = Join-Path $env:APPDATA "Hytale"
  Add-LogBuffer ("Checking default Hytale install at: {0}" -f $defaultRoot)
  if (Test-Path -LiteralPath $defaultRoot) {
    Add-LogBuffer "Found default Hytale install."
    $root = $defaultRoot
  } else {
    Add-LogBuffer "Default install not found; prompting for location."
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select your Hytale install folder"
    $dialog.ShowNewFolderButton = $false
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or
        [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
      Add-LogBuffer "Install location not provided."
      return $null
    }
    $root = $dialog.SelectedPath
    Add-LogBuffer ("User selected install folder: {0}" -f $root)
  }

  if ([IO.Path]::GetFileName($root) -ieq "UserData") {
    $userData = $root
  } else {
    $userData = Join-Path $root "UserData"
  }

  if (!(Test-Path -LiteralPath $userData)) {
    New-Item -ItemType Directory -Force -Path $userData | Out-Null
    Add-LogBuffer ("Created UserData folder: {0}" -f $userData)
  }

  return $userData
}

$UserDataDir = Get-HytaleUserDataDir
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
  Add-LogBuffer ("Missing links file: {0}" -f $LinksFile)
}
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Add-LogBuffer ("Ensured Mods folder exists: {0}" -f $DestDir)

$script:InstallIndex = Get-InstallIndex $InstallIndexFile
Add-LogBuffer ("Loaded install entries: {0}" -f $script:InstallIndex.mods.Count)

function Get-DownloadSnapshot {
  Get-ChildItem -LiteralPath $DownloadDir -File |
    Select-Object FullName, Name, Length, LastWriteTime
}

function Test-FileUnlocked([string]$path, [int]$timeoutSec) {
  Add-Log ("Checking file lock: {0}" -f $path)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
    if ($script:Abort) { return $false }
    try {
      $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $fs.Close()
      return $true
    } catch {
      Start-Sleep -Milliseconds $PollMs
      [System.Windows.Forms.Application]::DoEvents()
    }
  }
  Add-Log ("File still locked after timeout: {0}" -f $path)
  return $false
}

function Get-NewCompletedDownload($beforeSnapshot) {
  $before = @{}
  foreach ($f in $beforeSnapshot) { $before[$f.FullName] = $true }
  $loggedCandidates = @{}

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Milliseconds $PollMs
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:Abort) { return $null }

    # New files (not present before)
    $current = Get-ChildItem -LiteralPath $DownloadDir -File
    $newFiles = $current | Where-Object { -not $before.ContainsKey($_.FullName) }

    # If Firefox is still downloading, it often leaves a *.part file behind.
    # Wait until we see at least one new NON-.part file and no matching .part alongside it.
    foreach ($f in $newFiles) {
      if ($f.Extension -eq ".part") { continue }
      if (-not $loggedCandidates.ContainsKey($f.FullName)) {
        Add-Log ("Detected new file: {0}" -f $f.FullName)
        $loggedCandidates[$f.FullName] = $true
      }

      $partPath = $f.FullName + ".part"
      $hasPart = Test-Path -LiteralPath $partPath

      if (-not $hasPart) {
        # Extra safety: wait until size stabilizes across ten polls
        Add-Log ("Checking stability: {0}" -f $f.FullName)
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
          Start-Sleep -Milliseconds $PollMs
          [System.Windows.Forms.Application]::DoEvents()
          if ($script:Abort) { return $null }
        }
        if ($stable) {
          Add-Log ("Size stable: {0}" -f $f.FullName)
          $remaining = [Math]::Max(1, [int][Math]::Ceiling($TimeoutSec - $sw.Elapsed.TotalSeconds))
          if (Test-FileUnlocked $f.FullName $remaining) {
            return $f.FullName
          }
        }
      }
    }
  }

  return $null
}

function Close-FirefoxTab {
  # Best-effort: bring Firefox to front and send Ctrl+W
  try {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.AppActivate("Mozilla Firefox")
    Start-Sleep -Milliseconds 150
    $ws.SendKeys("^w")
  } catch {
    # If this fails, we don't hard-stop; you'll just have extra tabs
  }
}

$script:BrowserInfo = Get-DefaultBrowserInfo
$script:BrowserName = if ($script:BrowserInfo) { [IO.Path]::GetFileNameWithoutExtension($script:BrowserInfo.Exe) } else { "default browser" }
$script:BrowserInstanceArgs = if ($script:BrowserInfo) { Get-BrowserInstanceArgs $script:BrowserInfo.Exe } else { $null }
if ($script:BrowserInfo) {
  Add-LogBuffer ("Default browser: {0}" -f $script:BrowserName)
  if ($script:BrowserInstanceArgs) {
    Add-LogBuffer ("Launching in new window/instance: {0}" -f $script:BrowserInstanceArgs)
  } else {
    Add-LogBuffer "No new-window args for this browser; using default launch."
  }
  Add-LogBuffer "Browser windows will be left open to avoid affecting existing sessions."
} else {
  Add-LogBuffer "Default browser detection failed; using shell open."
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

$form = New-Object System.Windows.Forms.Form
$form.Text = "AMMAP Installer"
$form.FormBorderStyle = "FixedToolWindow"
$form.StartPosition = "Manual"
$form.Size = New-Object System.Drawing.Size(360, 300)

$screen = [System.Windows.Forms.Screen]::PrimaryScreen
if (-not $screen) {
  $screen = [System.Windows.Forms.Screen]::AllScreens | Select-Object -First 1
}
$wa = $screen.WorkingArea
if ($wa -is [System.Array]) {
  $wa = $wa | Select-Object -First 1
}
$margin = 12
$x = [int]$wa.Right - [int]$form.Width - $margin
$y = [int]$wa.Bottom - [int]$form.Height - $margin
$form.Location = New-Object System.Drawing.Point($x, $y)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.AutoSize = $false
$statusLabel.Size = New-Object System.Drawing.Size(330, 40)
$statusLabel.Location = New-Object System.Drawing.Point(12, 12)
$statusLabel.Text = "Ready."

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(12, 60)
$progressBar.Size = New-Object System.Drawing.Size(330, 18)
$progressBar.Minimum = 0
$progressBar.Maximum = [Math]::Max(1, $total)
$progressBar.Value = 0
$progressBar.Style = "Continuous"

$logList = New-Object System.Windows.Forms.ListBox
$logList.Location = New-Object System.Drawing.Point(12, 72)
$logList.Size = New-Object System.Drawing.Size(330, 160)
$logList.IntegralHeight = $false

foreach ($entry in $script:LogBuffer) {
  $logList.Items.Add($entry) | Out-Null
}
if ($logList.Items.Count -gt 0) {
  $logList.TopIndex = $logList.Items.Count - 1
}
$script:LogBuffer.Clear()

$abortButton = New-Object System.Windows.Forms.Button
$abortButton.Text = "Abort Install"
$abortButton.Size = New-Object System.Drawing.Size(110, 24)
$abortButton.Location = New-Object System.Drawing.Point(232, 240)
$abortButton.Add_Click({
  $script:Abort = $true
  $statusLabel.Text = "Abort requested..."
  Add-Log "Abort requested by user."
})

$form.Add_FormClosing({ $script:Abort = $true })

$form.Controls.AddRange(@($statusLabel, $progressBar, $logList, $abortButton))

function Add-Log([string]$text) {
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $logList.Items.Add("$stamp $text") | Out-Null
  $logList.TopIndex = $logList.Items.Count - 1
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status([string]$text) {
  $statusLabel.Text = $text
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress([int]$value) {
  if ($value -lt $progressBar.Minimum) { $value = $progressBar.Minimum }
  if ($value -gt $progressBar.Maximum) { $value = $progressBar.Maximum }
  $progressBar.Value = $value
  [System.Windows.Forms.Application]::DoEvents()
}

$form.Add_Shown({
  if ($total -eq 0) {
    if ($script:LinksFileMissing) {
      Set-Status "Missing modDownloadLinks.txt."
      Add-Log "Missing modDownloadLinks.txt."
    } else {
      Set-Status "No URLs found in modDownloadLinks.txt."
      Add-Log "No URLs found in modDownloadLinks.txt."
    }
    return
  }

  $completed = 0
  foreach ($url in $urls) {
    if ($script:Abort) { break }
    $cfInfo = ConvertFrom-CurseForgeUrl $url
    if ($cfInfo) {
      Add-Log ("Parsed CurseForge URL: fileId={0}, mod={1}" -f $cfInfo.FileId, $cfInfo.ModSlug)
    } else {
      Add-Log "URL not recognized as CurseForge format."
    }

    $existingEntry = $null
    if ($cfInfo -and $cfInfo.FileId) {
      $existingEntry = $script:InstallIndex.mods | Where-Object { $_.fileId -eq $cfInfo.FileId } | Select-Object -First 1
      if ($existingEntry -and $existingEntry.fileName) {
        $existingPath = Join-Path $DestDir $existingEntry.fileName
        if (Test-Path -LiteralPath $existingPath) {
          Set-Status ("Already installed: {0}" -f $existingEntry.fileName)
          Add-Log ("Skipping already installed fileId {0}: {1}" -f $cfInfo.FileId, $existingEntry.fileName)
          $completed++
          Set-Progress $completed
          continue
        }
      }
    }

    Set-Status ("Opening in {0}: {1}" -f $script:BrowserName, $url)
    Add-Log ("Opening in {0}: {1}" -f $script:BrowserName, $url)
    Write-Host "`nOpening: $url"

    Add-Log "Snapshot downloads folder."
    $before = Get-DownloadSnapshot

    # Open URL in the user's default browser
    Open-UrlInDefaultBrowser $url

    Set-Status "Waiting for download..."
    Add-Log "Waiting for download..."
    $downloadedPath = Get-NewCompletedDownload $before

    if ($script:Abort) { break }

    if (-not $downloadedPath) {
      Set-Status "Timed out waiting for download."
      Add-Log "Timed out waiting for download."
      Write-Warning "Timed out waiting for download. Leaving tab open and moving on."
      $completed++
      Set-Progress $completed
      continue
    }

    Set-Status ("Downloaded: {0}" -f $downloadedPath)
    Add-Log ("Downloaded: {0}" -f $downloadedPath)
    Write-Host "Downloaded: $downloadedPath"

    # Move into Mods folder (rename collisions safely)
    $name = [IO.Path]::GetFileName($downloadedPath)
    $dest = Join-Path $DestDir $name

    if (Test-Path -LiteralPath $dest) {
      $base = [IO.Path]::GetFileNameWithoutExtension($name)
      $ext  = [IO.Path]::GetExtension($name)
      $i = 1
      do {
        $dest = Join-Path $DestDir ("{0} ({1}){2}" -f $base, $i, $ext)
        $i++
      } while (Test-Path -LiteralPath $dest)
    }

    Move-Item -LiteralPath $downloadedPath -Destination $dest
    Set-Status ("Moved to: {0}" -f $dest)
    Add-Log ("Moved to: {0}" -f $dest)
    Write-Host "Moved to: $dest"

    Add-Log ("Reading manifest: {0}" -f $dest)
    $manifestInfo = Get-ModManifestInfo $dest
    $modName = $null
    $modVersion = $null
    if ($manifestInfo) {
      $modName = $manifestInfo.Name
      $modVersion = $manifestInfo.Version
      Add-Log ("Manifest: name={0}, version={1}" -f $modName, $modVersion)
    } else {
      Add-Log "Manifest info missing; recording file without name/version."
    }

    $fileId = if ($cfInfo) { $cfInfo.FileId } else { $null }
    $game = if ($cfInfo) { $cfInfo.Game } else { $null }
    $modSlug = if ($cfInfo) { $cfInfo.ModSlug } else { $null }
    $fileName = [IO.Path]::GetFileName($dest)

    if ($fileId) {
      $script:InstallIndex.mods = @($script:InstallIndex.mods | Where-Object { $_.fileId -ne $fileId })
    }

    if ($modName -and $modVersion) {
      $oldEntries = $script:InstallIndex.mods | Where-Object { $_.modName -eq $modName -and $_.version -ne $modVersion }
      foreach ($old in $oldEntries) {
        if ($old.fileName) {
          $oldPath = Join-Path $DestDir $old.fileName
          if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Force
            Add-Log ("Removed old version: {0}" -f $old.fileName)
          }
        }
      }
      $script:InstallIndex.mods = @($script:InstallIndex.mods | Where-Object { $_.modName -ne $modName -or $_.version -eq $modVersion })
    }

    $entry = [ordered]@{
      fileId = $fileId
      modName = $modName
      version = $modVersion
      fileName = $fileName
      url = $url
      game = $game
      modSlug = $modSlug
      installedAt = (Get-Date).ToString("s")
    }
    $script:InstallIndex.mods += [pscustomobject]$entry
    Set-InstallIndex $InstallIndexFile $script:InstallIndex
    Add-Log ("Updated install index: {0}" -f $InstallIndexFile)

    Start-Sleep -Milliseconds 250

    $completed++
    Set-Progress $completed
  }

  if ($script:Abort) {
    Set-Status "Aborted."
    Add-Log "Aborted."
    return
  }

  Set-Status "Done."
  Add-Log "Done."
  Write-Host "`nDone."
})

[System.Windows.Forms.Application]::Run($form)


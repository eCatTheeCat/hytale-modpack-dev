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
      Add-LogBuffer "Install location not provided." "error"
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
  Add-LogBuffer ("Missing links file: {0}" -f $LinksFile) "error"
}
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Add-LogBuffer ("Ensured Mods folder exists: {0}" -f $DestDir)

$script:InstallIndex = Get-HMDIndex $InstallIndexFile
Add-LogBuffer ("Loaded install entries: {0}" -f $script:InstallIndex.mods.Count)

$SavesDir = Join-Path $UserDataDir "Saves"
$SaveName = "AMMAP"
$SavePath = Join-Path $SavesDir $SaveName
$ConfigSource = Join-Path $PSScriptRoot "AMMAP_CONFIG"

function Get-BackupSavePath([string]$basePath) {
  $dir = Split-Path -Parent $basePath
  $base = (Split-Path -Leaf $basePath) + " old"
  $candidate = Join-Path $dir $base
  if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
  $i = 1
  do {
    $candidate = Join-Path $dir ("{0} ({1})" -f $base, $i)
    $i++
  } while (Test-Path -LiteralPath $candidate)
  return $candidate
}

function Copy-ConfigToSave([string]$sourceDir, [string]$destDir) {
  if (!(Test-Path -LiteralPath $sourceDir)) {
    Add-Log ("Config folder not found: {0}" -f $sourceDir) "error"
    return $false
  }
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  $items = Get-ChildItem -LiteralPath $sourceDir -Force
  if (-not $items) {
    Add-Log "AMMAP_CONFIG is empty; nothing to copy." "warn"
    return $true
  }
  foreach ($item in $items) {
    Copy-Item -LiteralPath $item.FullName -Destination $destDir -Recurse -Force
  }
  return $true
}

function Set-AmmapSave {
  if (!(Test-Path -LiteralPath $SavesDir)) {
    New-Item -ItemType Directory -Force -Path $SavesDir | Out-Null
    Add-Log ("Created Saves folder: {0}" -f $SavesDir)
  }

  if (!(Test-Path -LiteralPath $SavePath)) {
    Add-Log ("Save folder not found, creating: {0}" -f $SavePath)
    if (Copy-ConfigToSave $ConfigSource $SavePath) {
      Add-Log "Copied AMMAP_CONFIG into new save." "success"
    }
    return
  }

  $msg = "AMMAP save already exists.`n`nYes = Create New Save (rename existing)`nNo = Overwrite Existing Save`nCancel = Skip"
  $owner = $script:MainForm
  if ($owner) {
    $owner.TopMost = $true
    $owner.Activate()
  }
  $choice = if ($owner) {
    [System.Windows.Forms.MessageBox]::Show(
      $owner,
      $msg,
      "AMMAP Save",
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
  } else {
    [System.Windows.Forms.MessageBox]::Show(
      $msg,
      "AMMAP Save",
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
  }
  if ($owner) { $owner.TopMost = $false }

  if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
    $backupPath = Get-BackupSavePath $SavePath
    Move-Item -LiteralPath $SavePath -Destination $backupPath
    Add-Log ("Renamed existing save to: {0}" -f $backupPath)
    if (Copy-ConfigToSave $ConfigSource $SavePath) {
      Add-Log "Created new AMMAP save from AMMAP_CONFIG." "success"
    }
  } elseif ($choice -eq [System.Windows.Forms.DialogResult]::No) {
    Add-Log "Overwriting existing AMMAP save with AMMAP_CONFIG contents."
    if (Copy-ConfigToSave $ConfigSource $SavePath) {
      Add-Log "Merged AMMAP_CONFIG into existing save." "success"
    }
  } else {
    Add-Log "Save update skipped by user." "warn"
  }
}

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

$uiBg = [System.Drawing.Color]::FromArgb(22, 22, 22)
$uiPanelBg = [System.Drawing.Color]::FromArgb(30, 30, 30)
$uiLogBg = [System.Drawing.Color]::FromArgb(26, 26, 26)
$uiFg = [System.Drawing.Color]::Gainsboro
$uiSelectBg = [System.Drawing.Color]::FromArgb(45, 45, 45)
$uiButtonBg = [System.Drawing.Color]::FromArgb(45, 45, 45)
$uiButtonBorder = [System.Drawing.Color]::FromArgb(70, 70, 70)
$uiWarn = [System.Drawing.Color]::Gold
$uiError = [System.Drawing.Color]::Tomato
$uiSuccess = [System.Drawing.Color]::LimeGreen

$form = New-Object System.Windows.Forms.Form
$form.Text = "AMMAP Installer"
$form.FormBorderStyle = "SizableToolWindow"
$form.StartPosition = "Manual"
$form.Size = New-Object System.Drawing.Size(520, 340)
$form.MinimumSize = New-Object System.Drawing.Size(420, 260)
$form.BackColor = $uiBg
$script:MainForm = $form

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

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$layout.ColumnCount = 1
$layout.RowCount = 4
$layout.Padding = New-Object System.Windows.Forms.Padding(12)
$layout.BackColor = $uiBg
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.AutoSize = $false
$statusLabel.Text = "Ready."
$statusLabel.Height = 40
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$statusLabel.BackColor = $uiBg
$statusLabel.ForeColor = $uiFg

function New-ColorFromHue([double]$h) {
  $h = $h % 1
  if ($h -lt 0) { $h += 1 }
  $h = $h * 6
  $sector = [int][math]::Floor($h)
  $f = $h - $sector
  $q = 1 - $f
  $t = $f
  switch ($sector) {
    0 { $r = 1; $g = $t; $b = 0 }
    1 { $r = $q; $g = 1; $b = 0 }
    2 { $r = 0; $g = 1; $b = $t }
    3 { $r = 0; $g = $q; $b = 1 }
    4 { $r = $t; $g = 0; $b = 1 }
    default { $r = 1; $g = 0; $b = $q }
  }
  return [System.Drawing.Color]::FromArgb([int]($r * 255), [int]($g * 255), [int]($b * 255))
}

function New-RainbowBlend([double]$offset) {
  $colors = New-Object System.Collections.Generic.List[System.Drawing.Color]
  $positions = New-Object System.Collections.Generic.List[System.Single]
  for ($i = 0; $i -le 6; $i++) {
    $pos = $i / 6
    $colors.Add((New-ColorFromHue ($pos + $offset)))
    $positions.Add([single]$pos)
  }
  $blend = New-Object System.Drawing.Drawing2D.ColorBlend
  $blend.Colors = $colors.ToArray()
  $blend.Positions = $positions.ToArray()
  return $blend
}

$script:ProgressMax = [Math]::Max(1, $total)
$script:ProgressPercent = 0
$script:HueOffset = 0

$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Height = 22
$progressPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$progressPanel.BackColor = $uiPanelBg
$progressPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$progressPanel.Add_Paint({
  param($panel, $e)
  $g = $e.Graphics
  $rect = $panel.ClientRectangle
  $bgBrush = New-Object System.Drawing.SolidBrush($uiPanelBg)
  $g.FillRectangle($bgBrush, $rect)
  $bgBrush.Dispose()

  $w = [int]($rect.Width * ($script:ProgressPercent / 100))
  if ($w -gt 0) {
    $blend = New-RainbowBlend $script:HueOffset
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
      (New-Object System.Drawing.Point(0, 0)),
      (New-Object System.Drawing.Point([Math]::Max(1, $w), 0)),
      [System.Drawing.Color]::Red,
      [System.Drawing.Color]::Red
    )
    $brush.InterpolationColors = $blend
    $g.FillRectangle($brush, 0, 0, $w, $rect.Height)
    $brush.Dispose()
  }

  $pct = "{0}%" -f [int]$script:ProgressPercent
  $textSize = $g.MeasureString($pct, $form.Font)
  $tx = ($rect.Width - $textSize.Width) / 2
  $ty = ($rect.Height - $textSize.Height) / 2
  $textBrush = New-Object System.Drawing.SolidBrush($uiFg)
  $g.DrawString($pct, $form.Font, $textBrush, $tx, $ty)
  $textBrush.Dispose()
})

$logList = New-Object System.Windows.Forms.ListBox
$logList.Dock = [System.Windows.Forms.DockStyle]::Fill
$logList.BackColor = $uiLogBg
$logList.ForeColor = $uiFg
$logList.IntegralHeight = $false
$logList.HorizontalScrollbar = $true
$logList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$logList.ItemHeight = 18
$script:MaxLogWidth = 0
$logList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

function Get-LogColor([string]$level) {
  switch -Regex ($level) {
    '^warn' { return $uiWarn }
    '^err' { return $uiError }
    '^succ' { return $uiSuccess }
    default { return $uiFg }
  }
}

function Add-LogItem([string]$text, [string]$level = "info") {
  $item = [pscustomobject]@{
    Text = $text
    Level = $level
    Color = (Get-LogColor $level)
  }
  $logList.Items.Add($item) | Out-Null
  $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($text, $logList.Font).Width
  if ($textWidth -gt $script:MaxLogWidth) {
    $script:MaxLogWidth = $textWidth
    $logList.HorizontalExtent = $script:MaxLogWidth + 12
  }
}

$logList.Add_DrawItem({
  param($listBox, $e)
  if ($e.Index -lt 0) { return }
  $item = $listBox.Items[$e.Index]
  $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
  $bgColor = if ($isSelected) { $uiSelectBg } else { $listBox.BackColor }
  $fgColor = if ($isSelected) { [System.Drawing.Color]::White } else { $item.Color }
  $bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
  $e.Graphics.FillRectangle($bgBrush, $e.Bounds)
  [System.Windows.Forms.TextRenderer]::DrawText(
    $e.Graphics,
    $item.Text,
    $e.Font,
    $e.Bounds,
    $fgColor,
    $bgColor,
    [System.Windows.Forms.TextFormatFlags]::Left -bor
      [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
      [System.Windows.Forms.TextFormatFlags]::NoPrefix
  )
  $bgBrush.Dispose()
})

foreach ($entry in $script:LogBuffer) {
  if ($entry -is [string]) {
    Add-LogItem $entry "info"
  } else {
    Add-LogItem $entry.Text $entry.Level
  }
}
if ($logList.Items.Count -gt 0) {
  $logList.TopIndex = $logList.Items.Count - 1
}
$script:LogBuffer.Clear()

$abortButton = New-Object System.Windows.Forms.Button
$abortButton.Text = "Abort Install"
$abortButton.Size = New-Object System.Drawing.Size(110, 24)
$abortButton.BackColor = $uiButtonBg
$abortButton.ForeColor = $uiFg
$abortButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$abortButton.FlatAppearance.BorderColor = $uiButtonBorder
$abortButton.FlatAppearance.BorderSize = 1
$abortButton.Add_Click({
  $script:Abort = $true
  $statusLabel.Text = "Abort requested..."
  Add-Log "Abort requested by user."
})

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$buttonPanel.WrapContents = $false
$buttonPanel.AutoSize = $true
$buttonPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$buttonPanel.BackColor = $uiBg
$buttonPanel.Controls.Add($abortButton)

$form.Add_FormClosing({ $script:Abort = $true })

$layout.Controls.Add($statusLabel, 0, 0) | Out-Null
$layout.Controls.Add($progressPanel, 0, 1) | Out-Null
$layout.Controls.Add($logList, 0, 2) | Out-Null
$layout.Controls.Add($buttonPanel, 0, 3) | Out-Null
$form.Controls.Add($layout)

$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 40
$animTimer.Add_Tick({
  $script:HueOffset += 0.01
  if ($script:HueOffset -ge 1) { $script:HueOffset = 0 }
  $progressPanel.Invalidate()
})
$animTimer.Start()

function Add-Log([string]$text, [string]$level = "info") {
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $line = "$stamp $text"
  Add-LogItem $line $level
  $logList.TopIndex = $logList.Items.Count - 1
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status([string]$text) {
  $statusLabel.Text = $text
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress([int]$value) {
  if ($value -lt 0) { $value = 0 }
  if ($value -gt $script:ProgressMax) { $value = $script:ProgressMax }
  $script:ProgressPercent = [Math]::Min(100, [Math]::Max(0, [Math]::Round(($value / $script:ProgressMax) * 100)))
  $progressPanel.Invalidate()
  [System.Windows.Forms.Application]::DoEvents()
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

$form.Add_Shown({
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
        $script:ProgressMax = [Math]::Max(1, $script:ProgressMax + $retryUrls.Count)
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
  Set-AmmapSave
  Write-Host "`nDone."
})

[System.Windows.Forms.Application]::Run($form)


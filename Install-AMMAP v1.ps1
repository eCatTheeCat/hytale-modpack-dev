# Download-Mods.ps1
# Reads URLs from links.txt, opens each in Firefox, waits for a new download to complete, then moves it.

$LinksFile   = Join-Path $PSScriptRoot "modDownloadLinks.txt"
$DownloadDir = Join-Path $env:USERPROFILE "Downloads"
$DestDir     = Join-Path $PSScriptRoot "Mods"   # change if you want

$PollMs      = 50
$TimeoutSec  = 180

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Abort = $false

if (!(Test-Path $LinksFile)) { throw "Missing links file: $LinksFile" }
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

function Get-DownloadSnapshot {
  Get-ChildItem -LiteralPath $DownloadDir -File |
    Select-Object FullName, Name, Length, LastWriteTime
}

function Wait-NewDownloadComplete($beforeSnapshot) {
  $before = @{}
  foreach ($f in $beforeSnapshot) { $before[$f.FullName] = $true }

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

      $partPath = $f.FullName + ".part"
      $hasPart = Test-Path -LiteralPath $partPath

      if (-not $hasPart) {
        # Extra safety: wait until size stabilizes across five polls
        $stable = $true
        $prevSize = $null
        for ($i = 0; $i -lt 5; $i++) {
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
          return $f.FullName
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

$urls = Get-Content -LiteralPath $LinksFile |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and -not $_.StartsWith("#") }

$total = $urls.Count

$form = New-Object System.Windows.Forms.Form
$form.Text = "AMMAP Installer"
$form.FormBorderStyle = "FixedToolWindow"
$form.StartPosition = "Manual"
$form.Size = New-Object System.Drawing.Size(360, 300)

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$margin = 12
$form.Location = New-Object System.Drawing.Point($wa.Right - $form.Width - $margin, $wa.Bottom - $form.Height - $margin)

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
    Set-Status "No URLs found in modDownloadLinks.txt."
    Add-Log "No URLs found in modDownloadLinks.txt."
    return
  }

  $completed = 0
  foreach ($url in $urls) {
    if ($script:Abort) { break }
    Set-Status ("Opening: {0}" -f $url)
    Add-Log ("Opening: {0}" -f $url)
    Write-Host "`nOpening: $url"

    $before = Get-DownloadSnapshot

    # Open URL in Firefox (assumes Firefox is installed and in PATH)
    Start-Process "firefox.exe" -ArgumentList @("-new-tab", $url) | Out-Null

    Set-Status "Waiting for download..."
    Add-Log "Waiting for download..."
    $downloadedPath = Wait-NewDownloadComplete $before

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

    Close-FirefoxTab
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

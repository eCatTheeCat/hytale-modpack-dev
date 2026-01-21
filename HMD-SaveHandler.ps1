# HMD-SaveHandler.ps1
# Save folder workflow helpers for HMD.

Set-StrictMode -Version Latest

function Get-HMDHytaleUserDataDir([scriptblock]$onLogBuffer) {
  $defaultRoot = Join-Path $env:APPDATA "Hytale"
  if ($onLogBuffer) { & $onLogBuffer ("Checking default Hytale install at: {0}" -f $defaultRoot) "info" }
  if (Test-Path -LiteralPath $defaultRoot) {
    if ($onLogBuffer) { & $onLogBuffer "Found default Hytale install." "info" }
    $root = $defaultRoot
  } else {
    if ($onLogBuffer) { & $onLogBuffer "Default install not found; prompting for location." "info" }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select your Hytale install folder"
    $dialog.ShowNewFolderButton = $false
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or
        [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
      if ($onLogBuffer) { & $onLogBuffer "Install location not provided." "error" }
      return $null
    }
    $root = $dialog.SelectedPath
    if ($onLogBuffer) { & $onLogBuffer ("User selected install folder: {0}" -f $root) "info" }
  }

  if ([IO.Path]::GetFileName($root) -ieq "UserData") {
    $userData = $root
  } else {
    $userData = Join-Path $root "UserData"
  }

  if (!(Test-Path -LiteralPath $userData)) {
    New-Item -ItemType Directory -Force -Path $userData | Out-Null
    if ($onLogBuffer) { & $onLogBuffer ("Created UserData folder: {0}" -f $userData) "info" }
  }

  return $userData
}

function Get-HMDBackupSavePath([string]$basePath) {
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

function Copy-HMDConfigToSave([string]$sourceDir, [string]$destDir, [scriptblock]$onLog) {
  if (!(Test-Path -LiteralPath $sourceDir)) {
    if ($onLog) { & $onLog ("Config folder not found: {0}" -f $sourceDir) "error" }
    return $false
  }
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  $items = Get-ChildItem -LiteralPath $sourceDir -Force
  if (-not $items) {
    if ($onLog) { & $onLog "AMMAP_CONFIG is empty; nothing to copy." "warn" }
    return $true
  }
  foreach ($item in $items) {
    Copy-Item -LiteralPath $item.FullName -Destination $destDir -Recurse -Force
  }
  return $true
}

function Set-HMDSave {
  param(
    [string]$savesDir,
    [string]$saveName,
    [string]$configSource,
    [System.Windows.Forms.Form]$owner,
    [scriptblock]$onLog
  )

  $savePath = Join-Path $savesDir $saveName

  if (!(Test-Path -LiteralPath $savesDir)) {
    New-Item -ItemType Directory -Force -Path $savesDir | Out-Null
    if ($onLog) { & $onLog ("Created Saves folder: {0}" -f $savesDir) "info" }
  }

  if (!(Test-Path -LiteralPath $savePath)) {
    if ($onLog) { & $onLog ("Save folder not found, creating: {0}" -f $savePath) "info" }
    if (Copy-HMDConfigToSave $configSource $savePath $onLog) {
      if ($onLog) { & $onLog "Copied AMMAP_CONFIG into new save." "success" }
    }
    return
  }

  $msg = "AMMAP save already exists.`n`nYes = Create New Save (rename existing)`nNo = Overwrite Existing Save`nCancel = Skip"
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
    $backupPath = Get-HMDBackupSavePath $savePath
    Move-Item -LiteralPath $savePath -Destination $backupPath
    if ($onLog) { & $onLog ("Renamed existing save to: {0}" -f $backupPath) "info" }
    if (Copy-HMDConfigToSave $configSource $savePath $onLog) {
      if ($onLog) { & $onLog "Created new AMMAP save from AMMAP_CONFIG." "success" }
    }
  } elseif ($choice -eq [System.Windows.Forms.DialogResult]::No) {
    if ($onLog) { & $onLog "Overwriting existing AMMAP save with AMMAP_CONFIG contents." "info" }
    if (Copy-HMDConfigToSave $configSource $savePath $onLog) {
      if ($onLog) { & $onLog "Merged AMMAP_CONFIG into existing save." "success" }
    }
  } else {
    if ($onLog) { & $onLog "Save update skipped by user." "warn" }
  }
}

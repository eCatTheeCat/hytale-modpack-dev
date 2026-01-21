# HMD-Browser.ps1
# Browser detection and launch helpers for HMD.

Set-StrictMode -Version Latest

function Split-HMDBrowserCommandLine([string]$command) {
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

function New-HMDBrowserArguments([string]$browserArgs, [string]$url, [string]$prefixArgs) {
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

function Get-HMDBrowserInstanceArgs([string]$exePath) {
  if ([string]::IsNullOrWhiteSpace($exePath)) { return $null }
  $exeName = [IO.Path]::GetFileNameWithoutExtension($exePath).ToLowerInvariant()
  switch -Regex ($exeName) {
    '^firefox$' { return "-new-window" }
    '^(chrome|msedge|brave|vivaldi|opera)$' { return "--new-window" }
    default { return $null }
  }
}

function Get-HMDDefaultBrowserInfo {
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
  $parsed = Split-HMDBrowserCommandLine $cmd
  if (-not $parsed) { return $null }
  if ([IO.Path]::GetFileName($parsed.Exe) -ieq "rundll32.exe") { return $null }
  return $parsed
}

function Get-HMDBrowserState {
  $info = Get-HMDDefaultBrowserInfo
  $name = if ($info) { [IO.Path]::GetFileNameWithoutExtension($info.Exe) } else { "default browser" }
  $instanceArgs = if ($info) { Get-HMDBrowserInstanceArgs $info.Exe } else { $null }
  return [pscustomobject]@{
    Info = $info
    Name = $name
    InstanceArgs = $instanceArgs
    SessionOpened = $false
  }
}

function Stop-HMDFirefoxWindow {
  # Best-effort: bring Firefox to front and send Ctrl+Shift+W (close window)
  try {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.AppActivate("Mozilla Firefox")
    Start-Sleep -Milliseconds 150
    $ws.SendKeys("^+w")
  } catch {
    # If this fails, we don't hard-stop; window may stay open
  }
}

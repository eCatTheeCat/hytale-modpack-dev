# HMD-Config.ps1
# Shared defaults for HMD.

Set-StrictMode -Version Latest

function Get-HMDDefaults {
  return [pscustomobject]@{
    UiTitle = "AMMAP Installer"
    SaveName = "AMMAP"
    ConfigDirName = "AMMAP_CONFIG"
    ModsDirName = "Mods"
    LinksFileName = "modDownloadLinks.txt"
    DownloadDir = (Join-Path $env:USERPROFILE "Downloads")
    BrowserWindowDelayMs = 400
    PollMs = 50
    TimeoutSec = 180
    MinStableAgeMs = 1000
    NoFileTimeoutSec = 10
  }
}

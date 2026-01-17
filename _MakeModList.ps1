# MakeModList.ps1
# Generates names.txt in the folder this script is run from.

$OutName = "_ModList.txt"
$OutFile = Join-Path $PWD $OutName

# Zip support
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null

# Determine script name (so we can ignore it)
$ThisScriptName = $null
try {
    if ($PSCommandPath) { $ThisScriptName = [System.IO.Path]::GetFileName($PSCommandPath) }
} catch {}

$lines = New-Object System.Collections.Generic.List[string]

Get-ChildItem -File -LiteralPath $PWD -Include *.jar, *.zip | ForEach-Object {
    $file = $_

    # Ignore output file and (if applicable) this script
    if ($file.Name -ieq $OutName) { return }
    if ($ThisScriptName -and ($file.Name -ieq $ThisScriptName)) { return }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -replace "_", " "

    $hasVersionInName = $base -match '\b\d+\.\d+\.\d+\b$'
    $version = $null
    $zip = $null

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)

        $entry = $zip.Entries |
            Where-Object { $_.FullName -match '(?i)(^|/|\\)manifest\.json$' } |
            Select-Object -First 1

        if ($entry) {
            $stream = $entry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()

            # Prefer JSON parse
            try {
                $obj = $text | ConvertFrom-Json -ErrorAction Stop
                if ($obj.Version) { $version = [string]$obj.Version }
                elseif ($obj.version) { $version = [string]$obj.version }
            } catch {
                if ($text -match '(?i)"version"\s*:\s*"([^"]+)"') { $version = $matches[1] }
            }

            # Reduce to x.x.x if present
            if ($version) {
                $m = [regex]::Match($version, '\d+\.\d+\.\d+')
                if ($m.Success) { $version = $m.Value } else { $version = $null }
            }
        }
    } catch {
        # unreadable archive -> no version
    } finally {
        if ($zip) { $zip.Dispose() }
    }

    if (-not $hasVersionInName -and $version) {
        $lines.Add("$base $version")
    } else {
        $lines.Add($base)
    }
}

$lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "Wrote $($lines.Count) lines to: $OutFile"
# WinForms-Style-Test.ps1
# UI styling sandbox for AMMAP.

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

try {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
  Write-Host "WinForms failed to load. Use Windows PowerShell 5.1 or install .NET Desktop Runtime."
  exit 1
}

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

$bg = [System.Drawing.Color]::FromArgb(22, 22, 22)
$panelBg = [System.Drawing.Color]::FromArgb(30, 30, 30)
$fg = [System.Drawing.Color]::Gainsboro
$form = New-Object System.Windows.Forms.Form
$form.Text = "WinForms Style Test"
$form.Size = New-Object System.Drawing.Size(680, 440)
$form.MinimumSize = New-Object System.Drawing.Size(520, 360)
$form.BackColor = $bg

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$layout.ColumnCount = 1
$layout.RowCount = 4
$layout.Padding = New-Object System.Windows.Forms.Padding(12)
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready. This is a dark mode styling test."
$statusLabel.ForeColor = $fg
$statusLabel.BackColor = $bg
$statusLabel.Height = 40
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Height = 22
$progressPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$progressPanel.BackColor = $panelBg
$progressPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$logList = New-Object System.Windows.Forms.ListBox
$logList.Dock = [System.Windows.Forms.DockStyle]::Fill
$logList.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
$logList.ForeColor = $fg
$logList.IntegralHeight = $false
$logList.HorizontalScrollbar = $true
$logList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$logList.ItemHeight = 18
$logList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$buttonPanel.WrapContents = $false
$buttonPanel.AutoSize = $true
$buttonPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0)

$btnAddInfo = New-Object System.Windows.Forms.Button
$btnAddInfo.Text = "Add Info"
$btnAddWarn = New-Object System.Windows.Forms.Button
$btnAddWarn.Text = "Add Warn"
$btnAddError = New-Object System.Windows.Forms.Button
$btnAddError.Text = "Add Error"
$btnAddOk = New-Object System.Windows.Forms.Button
$btnAddOk.Text = "Add Success"
$btnProgress = New-Object System.Windows.Forms.Button
$btnProgress.Text = "Advance Progress"

function Set-ButtonStyle([System.Windows.Forms.Button]$btn) {
  $btn.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
  $btn.ForeColor = $fg
  $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
  $btn.FlatAppearance.BorderSize = 1
}

Set-ButtonStyle $btnAddInfo
Set-ButtonStyle $btnAddWarn
Set-ButtonStyle $btnAddError
Set-ButtonStyle $btnAddOk
Set-ButtonStyle $btnProgress

$buttonPanel.Controls.AddRange(@($btnProgress, $btnAddOk, $btnAddError, $btnAddWarn, $btnAddInfo))

$layout.Controls.Add($statusLabel, 0, 0) | Out-Null
$layout.Controls.Add($progressPanel, 0, 1) | Out-Null
$layout.Controls.Add($logList, 0, 2) | Out-Null
$layout.Controls.Add($buttonPanel, 0, 3) | Out-Null
$form.Controls.Add($layout)

$script:LogMaxWidth = 0
function Add-LogLine([string]$text, [object]$color) {
  if ($color -is [System.Drawing.Color]) {
    $useColor = $color
  } elseif ($null -ne $color) {
    $useColor = [System.Drawing.Color]::FromName([string]$color)
  } else {
    $useColor = $fg
  }
  if ($useColor.IsEmpty) { $useColor = $fg }
  $item = [pscustomobject]@{
    Text = $text
    Color = $useColor
  }
  $logList.Items.Add($item) | Out-Null
  $width = [System.Windows.Forms.TextRenderer]::MeasureText($text, $logList.Font).Width
  if ($width -gt $script:LogMaxWidth) {
    $script:LogMaxWidth = $width
    $logList.HorizontalExtent = $script:LogMaxWidth + 12
  }
  $logList.TopIndex = $logList.Items.Count - 1
}

$logList.Add_DrawItem({
  param($listBox, $e)
  if ($e.Index -lt 0) { return }
  $item = $listBox.Items[$e.Index]
  $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
  $bgColor = if ($isSelected) { [System.Drawing.Color]::FromArgb(45, 45, 45) } else { $listBox.BackColor }
  $fgColor = if ($isSelected) { [System.Drawing.Color]::White } else { $item.Color }
  $bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
  $fgBrush = New-Object System.Drawing.SolidBrush($fgColor)
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
  $fgBrush.Dispose()
})

$script:ProgressValue = 0
$script:HueOffset = 0
$progressPanel.Add_Paint({
  param($panel, $e)
  $g = $e.Graphics
  $rect = $panel.ClientRectangle
  $bgBrush = New-Object System.Drawing.SolidBrush($panelBg)
  $g.FillRectangle($bgBrush, $rect)
  $bgBrush.Dispose()

  $w = [int]($rect.Width * ($script:ProgressValue / 100))
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

  $pct = "{0}%" -f [int]$script:ProgressValue
  $textSize = $g.MeasureString($pct, $form.Font)
  $tx = ($rect.Width - $textSize.Width) / 2
  $ty = ($rect.Height - $textSize.Height) / 2
  $textBrush = New-Object System.Drawing.SolidBrush($fg)
  $g.DrawString($pct, $form.Font, $textBrush, $tx, $ty)
  $textBrush.Dispose()
})

$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 40
$animTimer.Add_Tick({
  $script:HueOffset += 0.01
  if ($script:HueOffset -ge 1) { $script:HueOffset = 0 }
  $progressPanel.Invalidate()
})
$animTimer.Start()

$btnAddInfo.Add_Click({ Add-LogLine -text ("Info: " + (Get-Date).ToString("T")) -color $fg })
$btnAddWarn.Add_Click({ Add-LogLine -text ("Warn: " + (Get-Date).ToString("T")) -color "Gold" })
$btnAddError.Add_Click({ Add-LogLine -text ("Error: " + (Get-Date).ToString("T")) -color "Tomato" })
$btnAddOk.Add_Click({ Add-LogLine -text ("Success: " + (Get-Date).ToString("T")) -color "LimeGreen" })
$btnProgress.Add_Click({
  $script:ProgressValue += 10
  if ($script:ProgressValue -gt 100) { $script:ProgressValue = 0 }
  $progressPanel.Invalidate()
})

Add-LogLine -text "Info: UI initialized." -color $fg
Add-LogLine -text "Warn: Example warning line." -color "Gold"
Add-LogLine -text "Error: Example error line." -color "Tomato"
Add-LogLine -text "Success: Example very very very very very extremely long success line, like it's just so very very very very long, wow this is so long, i almost can't believe it." -color "LimeGreen"

[System.Windows.Forms.Application]::Run($form)

# HMD-Ui.ps1
# WinForms UI helpers for HMD.

Set-StrictMode -Version Latest

function New-HMDColorFromHue([double]$h) {
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

function New-HMDRainbowBlend([double]$offset) {
  $colors = New-Object System.Collections.Generic.List[System.Drawing.Color]
  $positions = New-Object System.Collections.Generic.List[System.Single]
  for ($i = 0; $i -le 6; $i++) {
    $pos = $i / 6
    $colors.Add((New-HMDColorFromHue ($pos + $offset)))
    $positions.Add([single]$pos)
  }
  $blend = New-Object System.Drawing.Drawing2D.ColorBlend
  $blend.Colors = $colors.ToArray()
  $blend.Positions = $positions.ToArray()
  return $blend
}

function Get-HMDLogColor([object]$ui, [string]$level) {
  switch -Regex ($level) {
    '^warn' { return $ui.Colors.Warn }
    '^err' { return $ui.Colors.Error }
    '^succ' { return $ui.Colors.Success }
    default { return $ui.Colors.Fg }
  }
}

function Add-HMDLogItem([object]$ui, [string]$text, [string]$level = "info") {
  $item = [pscustomobject]@{
    Text = $text
    Level = $level
    Color = (Get-HMDLogColor $ui $level)
  }
  $ui.LogList.Items.Add($item) | Out-Null
  $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($text, $ui.LogList.Font).Width
  if ($textWidth -gt $ui.MaxLogWidth) {
    $ui.MaxLogWidth = $textWidth
    $ui.LogList.HorizontalExtent = $ui.MaxLogWidth + 12
  }
}

function Add-HMDLog([object]$ui, [string]$text, [string]$level = "info") {
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $line = "$stamp $text"
  Add-HMDLogItem $ui $line $level
  if ($ui.LogList.Items.Count -gt 0) {
    $ui.LogList.TopIndex = $ui.LogList.Items.Count - 1
  }
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-HMDStatus([object]$ui, [string]$text) {
  $ui.StatusLabel.Text = $text
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-HMDProgress([object]$ui, [int]$value) {
  if ($value -lt 0) { $value = 0 }
  if ($value -gt $ui.ProgressMax) { $value = $ui.ProgressMax }
  $ui.ProgressPercent = [Math]::Min(100, [Math]::Max(0, [Math]::Round(($value / $ui.ProgressMax) * 100)))
  $ui.ProgressPanel.Invalidate()
  [System.Windows.Forms.Application]::DoEvents()
}

function New-HMDUi {
  param(
    [int]$totalCount,
    [System.Collections.Generic.List[object]]$logBuffer,
    [scriptblock]$onAbort,
    [string]$title = "AMMAP Installer"
  )

  $colors = [pscustomobject]@{
    Bg = [System.Drawing.Color]::FromArgb(22, 22, 22)
    PanelBg = [System.Drawing.Color]::FromArgb(30, 30, 30)
    LogBg = [System.Drawing.Color]::FromArgb(26, 26, 26)
    Fg = [System.Drawing.Color]::Gainsboro
    SelectBg = [System.Drawing.Color]::FromArgb(45, 45, 45)
    ButtonBg = [System.Drawing.Color]::FromArgb(45, 45, 45)
    ButtonBorder = [System.Drawing.Color]::FromArgb(70, 70, 70)
    Warn = [System.Drawing.Color]::Gold
    Error = [System.Drawing.Color]::Tomato
    Success = [System.Drawing.Color]::LimeGreen
  }

  $ui = [pscustomobject]@{
    Colors = $colors
    ProgressMax = [Math]::Max(1, $totalCount)
    ProgressPercent = 0
    HueOffset = 0
    MaxLogWidth = 0
  }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = $title
  $form.FormBorderStyle = "SizableToolWindow"
  $form.StartPosition = "Manual"
  $form.Size = New-Object System.Drawing.Size(520, 340)
  $form.MinimumSize = New-Object System.Drawing.Size(420, 260)
  $form.BackColor = $colors.Bg
  $ui | Add-Member -NotePropertyName Form -NotePropertyValue $form

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
  $layout.BackColor = $colors.Bg
  $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
  $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
  $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
  $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

  $statusLabel = New-Object System.Windows.Forms.Label
  $statusLabel.AutoSize = $false
  $statusLabel.Text = "Ready."
  $statusLabel.Height = 40
  $statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
  $statusLabel.BackColor = $colors.Bg
  $statusLabel.ForeColor = $colors.Fg
  $ui | Add-Member -NotePropertyName StatusLabel -NotePropertyValue $statusLabel

  $progressPanel = New-Object System.Windows.Forms.Panel
  $progressPanel.Height = 22
  $progressPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $progressPanel.BackColor = $colors.PanelBg
  $progressPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
  $ui | Add-Member -NotePropertyName ProgressPanel -NotePropertyValue $progressPanel

  $progressPanel.Add_Paint({
    param($panel, $e)
    $g = $e.Graphics
    $rect = $panel.ClientRectangle
    $bgBrush = New-Object System.Drawing.SolidBrush($ui.Colors.PanelBg)
    $g.FillRectangle($bgBrush, $rect)
    $bgBrush.Dispose()

    $w = [int]($rect.Width * ($ui.ProgressPercent / 100))
    if ($w -gt 0) {
      $blend = New-HMDRainbowBlend $ui.HueOffset
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

    $pct = "{0}%" -f [int]$ui.ProgressPercent
    $textSize = $g.MeasureString($pct, $panel.Font)
    $tx = ($rect.Width - $textSize.Width) / 2
    $ty = ($rect.Height - $textSize.Height) / 2
    $textBrush = New-Object System.Drawing.SolidBrush($ui.Colors.Fg)
    $g.DrawString($pct, $panel.Font, $textBrush, $tx, $ty)
    $textBrush.Dispose()
  })

  $logList = New-Object System.Windows.Forms.ListBox
  $logList.Dock = [System.Windows.Forms.DockStyle]::Fill
  $logList.BackColor = $colors.LogBg
  $logList.ForeColor = $colors.Fg
  $logList.IntegralHeight = $false
  $logList.HorizontalScrollbar = $true
  $logList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
  $logList.ItemHeight = 18
  $logList.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
  $ui | Add-Member -NotePropertyName LogList -NotePropertyValue $logList

  $logList.Add_DrawItem({
    param($listBox, $e)
    if ($e.Index -lt 0) { return }
    $item = $listBox.Items[$e.Index]
    $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $bgColor = if ($isSelected) { $ui.Colors.SelectBg } else { $listBox.BackColor }
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

  if ($logBuffer) {
    foreach ($entry in $logBuffer) {
      if ($entry -is [string]) {
        Add-HMDLogItem $ui $entry "info"
      } else {
        Add-HMDLogItem $ui $entry.Text $entry.Level
      }
    }
    if ($logList.Items.Count -gt 0) {
      $logList.TopIndex = $logList.Items.Count - 1
    }
    $logBuffer.Clear()
  }

  $abortButton = New-Object System.Windows.Forms.Button
  $abortButton.Text = "Abort Install"
  $abortButton.Size = New-Object System.Drawing.Size(110, 24)
  $abortButton.BackColor = $colors.ButtonBg
  $abortButton.ForeColor = $colors.Fg
  $abortButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $abortButton.FlatAppearance.BorderColor = $colors.ButtonBorder
  $abortButton.FlatAppearance.BorderSize = 1
  $ui | Add-Member -NotePropertyName AbortHandler -NotePropertyValue $onAbort
  $abortButton.Add_Click({
    if ($ui.AbortHandler) { & $ui.AbortHandler $ui }
  })

  $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
  $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
  $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $buttonPanel.WrapContents = $false
  $buttonPanel.AutoSize = $true
  $buttonPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0)
  $buttonPanel.BackColor = $colors.Bg
  $buttonPanel.Controls.Add($abortButton)

  $form.Add_FormClosing({
    if ($ui.AbortHandler) { & $ui.AbortHandler $ui }
  })

  $layout.Controls.Add($statusLabel, 0, 0) | Out-Null
  $layout.Controls.Add($progressPanel, 0, 1) | Out-Null
  $layout.Controls.Add($logList, 0, 2) | Out-Null
  $layout.Controls.Add($buttonPanel, 0, 3) | Out-Null
  $form.Controls.Add($layout)

  $animTimer = New-Object System.Windows.Forms.Timer
  $animTimer.Interval = 40
  $animTimer.Add_Tick({
    $ui.HueOffset += 0.01
    if ($ui.HueOffset -ge 1) { $ui.HueOffset = 0 }
    $ui.ProgressPanel.Invalidate()
  })
  $animTimer.Start()
  $ui | Add-Member -NotePropertyName AnimTimer -NotePropertyValue $animTimer

  return $ui
}

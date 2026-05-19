#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$assetDir = Join-Path $repoRoot 'assets'
$docsAssetDir = Join-Path $repoRoot 'docs\assets'
New-Item -ItemType Directory -Force -Path $assetDir, $docsAssetDir | Out-Null

function New-RoundedRectanglePath {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.RectangleF]$Rectangle,
        [float]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2
    $arc = [System.Drawing.RectangleF]::new($Rectangle.X, $Rectangle.Y, $diameter, $diameter)
    $path.AddArc($arc, 180, 90)
    $arc.X = $Rectangle.Right - $diameter
    $path.AddArc($arc, 270, 90)
    $arc.Y = $Rectangle.Bottom - $diameter
    $path.AddArc($arc, 0, 90)
    $arc.X = $Rectangle.X
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()
    return $path
}

function Fill-RoundedRectangle {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)][System.Drawing.Brush]$Brush,
        [Parameter(Mandatory = $true)][System.Drawing.RectangleF]$Rectangle,
        [float]$Radius = 8
    )
    $path = New-RoundedRectanglePath -Rectangle $Rectangle -Radius $Radius
    $Graphics.FillPath($Brush, $path)
    $path.Dispose()
}

function Draw-RoundedRectangle {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)][System.Drawing.Pen]$Pen,
        [Parameter(Mandatory = $true)][System.Drawing.RectangleF]$Rectangle,
        [float]$Radius = 8
    )
    $path = New-RoundedRectanglePath -Rectangle $Rectangle -Radius $Radius
    $Graphics.DrawPath($Pen, $path)
    $path.Dispose()
}

$previewPath = Join-Path $docsAssetDir 'app-preview.png'
$bitmap = New-Object System.Drawing.Bitmap 1400, 900
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$bg = [System.Drawing.Color]::FromArgb(17, 17, 19)
$panel = [System.Drawing.Color]::FromArgb(31, 31, 35)
$panel2 = [System.Drawing.Color]::FromArgb(24, 24, 27)
$line = [System.Drawing.Color]::FromArgb(63, 63, 70)
$text = [System.Drawing.Color]::FromArgb(244, 244, 245)
$muted = [System.Drawing.Color]::FromArgb(161, 161, 170)
$teal = [System.Drawing.Color]::FromArgb(15, 118, 110)
$amber = [System.Drawing.Color]::FromArgb(245, 158, 11)
$green = [System.Drawing.Color]::FromArgb(34, 197, 94)

$graphics.Clear($bg)
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)
$fontH = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Regular)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
$fontMono = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Regular)

$brushText = New-Object System.Drawing.SolidBrush($text)
$brushMuted = New-Object System.Drawing.SolidBrush($muted)
$brushPanel = New-Object System.Drawing.SolidBrush($panel)
$brushPanel2 = New-Object System.Drawing.SolidBrush($panel2)
$brushTeal = New-Object System.Drawing.SolidBrush($teal)
$brushAmber = New-Object System.Drawing.SolidBrush($amber)
$brushGreen = New-Object System.Drawing.SolidBrush($green)
$penLine = New-Object System.Drawing.Pen($line, 2)

$outer = [System.Drawing.RectangleF]::new(70, 55, 1260, 790)
Fill-RoundedRectangle $graphics $brushPanel2 $outer 12
Draw-RoundedRectangle $graphics $penLine $outer 12

$graphics.DrawString('VM Partition Workbench', $fontTitle, $brushText, 105, 90)
$graphics.DrawString('VMware-first resize planning, VHD attach, and GParted boot prep', $font, $brushMuted, 110, 145)

Fill-RoundedRectangle $graphics $brushTeal ([System.Drawing.RectangleF]::new(1080, 98, 180, 46)) 8
$graphics.DrawString('Build plan', $font, $brushText, 1126, 110)

Fill-RoundedRectangle $graphics $brushPanel ([System.Drawing.RectangleF]::new(105, 195, 340, 560)) 8
Draw-RoundedRectangle $graphics $penLine ([System.Drawing.RectangleF]::new(105, 195, 340, 560)) 8
$graphics.DrawString('Selected virtual disk', $fontH, $brushText, 130, 225)
$graphics.DrawString('Win11-Dev.vmx', $font, $brushText, 132, 280)
$graphics.DrawString('Disk: scsi0:0 - WindowsDev.vmdk', $fontSmall, $brushMuted, 132, 312)
$graphics.DrawString('Capacity: 80.00 GB', $fontSmall, $brushMuted, 132, 338)
$graphics.DrawString('File backup: enabled', $fontSmall, $brushGreen, 132, 364)

Fill-RoundedRectangle $graphics $brushTeal ([System.Drawing.RectangleF]::new(132, 420, 120, 42)) 6
$graphics.DrawString('Inspect', $fontSmall, $brushText, 170, 432)
Fill-RoundedRectangle $graphics $brushPanel2 ([System.Drawing.RectangleF]::new(264, 420, 120, 42)) 6
Draw-RoundedRectangle $graphics $penLine ([System.Drawing.RectangleF]::new(264, 420, 120, 42)) 6
$graphics.DrawString('Mount VHD', $fontSmall, $brushText, 294, 432)

$graphics.DrawString('Safety rail', $fontH, $brushText, 132, 510)
$graphics.DrawString('Blocks host boot/system disks', $fontSmall, $brushMuted, 132, 548)
$graphics.DrawString('Warns before destructive work', $fontSmall, $brushMuted, 132, 576)
$graphics.DrawString('Logs every native command', $fontSmall, $brushMuted, 132, 604)

Fill-RoundedRectangle $graphics $brushPanel ([System.Drawing.RectangleF]::new(480, 195, 780, 250)) 8
Draw-RoundedRectangle $graphics $penLine ([System.Drawing.RectangleF]::new(480, 195, 780, 250)) 8
$graphics.DrawString('Plan', $fontH, $brushText, 510, 225)
$planLines = @(
    '1. Create virtual disk backup',
    '   Copy selected VMDK files beside the source disk.',
    '2. Expand VMDK capacity to 120 GB',
    '   vmware-vdiskmanager.exe -x 120GB WindowsDev.vmdk',
    '3. Attach GParted Live ISO to VMX',
    '   Boot VM to move or grow partitions safely.'
)
$y = 272
foreach ($lineText in $planLines) {
    $graphics.DrawString($lineText, $fontMono, $brushText, 515, $y)
    $y += 30
}

Fill-RoundedRectangle $graphics $brushPanel ([System.Drawing.RectangleF]::new(480, 475, 780, 280)) 8
Draw-RoundedRectangle $graphics $penLine ([System.Drawing.RectangleF]::new(480, 475, 780, 280)) 8
$graphics.DrawString('Mounted disk view', $fontH, $brushText, 510, 505)
$headers = @('#', 'Name', 'Bus', 'Size', 'Boot', 'System')
$xs = @(520, 590, 860, 960, 1070, 1150)
for ($i = 0; $i -lt $headers.Count; $i++) {
    $graphics.DrawString($headers[$i], $fontSmall, $brushMuted, $xs[$i], 555)
}
$rows = @(
    @('0', 'Samsung SSD', 'NVMe', '1.82 TB', 'True', 'True'),
    @('3', 'Msft Virtual Disk', 'File', '120 GB', 'False', 'False')
)
$y = 594
foreach ($row in $rows) {
    if ($row[0] -eq '3') {
        Fill-RoundedRectangle $graphics $brushTeal ([System.Drawing.RectangleF]::new(510, $y - 8, 710, 34)) 4
    }
    for ($i = 0; $i -lt $row.Count; $i++) {
        $graphics.DrawString($row[$i], $fontSmall, $brushText, $xs[$i], $y)
    }
    $y += 48
}
$graphics.DrawString('Native Resize-Partition can target mounted VM disks. Moves are handled inside the guest with GParted.', $fontSmall, $brushMuted, 515, 710)

$bitmap.Save($previewPath, [System.Drawing.Imaging.ImageFormat]::Png)

$iconBitmap = New-Object System.Drawing.Bitmap 256, 256
$iconGraphics = [System.Drawing.Graphics]::FromImage($iconBitmap)
$iconGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$iconGraphics.Clear([System.Drawing.Color]::Transparent)
Fill-RoundedRectangle $iconGraphics $brushPanel2 ([System.Drawing.RectangleF]::new(18, 18, 220, 220)) 36
Fill-RoundedRectangle $iconGraphics $brushTeal ([System.Drawing.RectangleF]::new(44, 56, 168, 52)) 16
Fill-RoundedRectangle $iconGraphics $brushAmber ([System.Drawing.RectangleF]::new(44, 128, 104, 52)) 16
Fill-RoundedRectangle $iconGraphics $brushGreen ([System.Drawing.RectangleF]::new(158, 128, 54, 52)) 16
$iconGraphics.DrawString('VM', (New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)), $brushText, 84, 64)
$logoPngPath = Join-Path $assetDir 'vm-partition-workbench.png'
$iconBitmap.Save($logoPngPath, [System.Drawing.Imaging.ImageFormat]::Png)
$iconHandle = $iconBitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($iconHandle)
$iconPath = Join-Path $assetDir 'vm-partition-workbench.ico'
$stream = [System.IO.File]::Open($iconPath, [System.IO.FileMode]::Create)
try {
    $icon.Save($stream)
}
finally {
    $stream.Dispose()
    $icon.Dispose()
    $iconGraphics.Dispose()
    $iconBitmap.Dispose()
}

$graphics.Dispose()
$bitmap.Dispose()
$fontTitle.Dispose()
$fontH.Dispose()
$font.Dispose()
$fontSmall.Dispose()
$fontMono.Dispose()
$brushText.Dispose()
$brushMuted.Dispose()
$brushPanel.Dispose()
$brushPanel2.Dispose()
$brushTeal.Dispose()
$brushAmber.Dispose()
$brushGreen.Dispose()
$penLine.Dispose()

Write-Host "Generated $previewPath"
Write-Host "Generated $logoPngPath"
Write-Host "Generated $iconPath"

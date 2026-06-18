$ErrorActionPreference = "Stop"

# Assets live one level up from this script (src/Assets).
$assetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets'
New-Item -Path $assetDir -ItemType Directory -Force | Out-Null

Add-Type -AssemblyName System.Drawing

$size = 256
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb(30, 90, 185),
    [System.Drawing.Color]::FromArgb(18, 44, 96),
    45)
$g.FillRectangle($bg, $rect)

$ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 255, 255, 255), 10)
$g.DrawEllipse($ringPen, 14, 14, $size - 28, $size - 28)

$font = New-Object System.Drawing.Font("Segoe UI", 154, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center

$shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
$textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(246, 255, 255, 255))

$g.DrawString("M", $font, $shadowBrush, [System.Drawing.RectangleF]::new(4, 8, $size, $size), $sf)
$g.DrawString("M", $font, $textBrush, [System.Drawing.RectangleF]::new(0, 0, $size, $size), $sf)

$pngPath = Join-Path $assetDir "tray-icon.png"
$icoPath = Join-Path $assetDir "tray-icon.ico"

$bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = $ms.ToArray()

$fs = [System.IO.File]::Open($icoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
$bw = New-Object System.IO.BinaryWriter($fs)

# ICONDIR
$bw.Write([UInt16]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]1)

# ICONDIRENTRY (0 width/height means 256)
$bw.Write([Byte]0)
$bw.Write([Byte]0)
$bw.Write([Byte]0)
$bw.Write([Byte]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]32)
$bw.Write([UInt32]$pngBytes.Length)
$bw.Write([UInt32]22)

# PNG image data
$bw.Write($pngBytes)
$bw.Flush()
$bw.Close()

$g.Dispose()
$bg.Dispose()
$ringPen.Dispose()
$font.Dispose()
$sf.Dispose()
$shadowBrush.Dispose()
$textBrush.Dispose()
$bmp.Dispose()
$ms.Dispose()

Write-Output "Updated icon files: $icoPath and $pngPath"

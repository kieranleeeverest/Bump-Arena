$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$previewRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$geometry = Get-Content -LiteralPath (Join-Path $previewRoot 'geometry_options.json') -Raw | ConvertFrom-Json

function Draw-Disc($graphics, [float]$x, [float]$y, [float]$radius, [bool]$blue) {
    $shadow = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(125, 0, 0, 0))
    $rim = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 149, 102, 141))
    $innerColor = if ($blue) { [System.Drawing.Color]::FromArgb(255, 35, 131, 167) } else { [System.Drawing.Color]::FromArgb(255, 164, 55, 91) }
    $body = [System.Drawing.SolidBrush]::new($innerColor)
    $detail = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(220, 237, 179, 204), 1.2)
    $glint = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(160, 235, 238, 255))
    $graphics.FillEllipse($shadow, $x - $radius + 2, $y - $radius + 3, $radius * 2 + 3, $radius * 2 + 3)
    $graphics.FillEllipse($rim, $x - $radius, $y - $radius, $radius * 2, $radius * 2)
    $graphics.FillEllipse($body, $x - $radius + 3, $y - $radius + 3, $radius * 2 - 6, $radius * 2 - 6)
    $graphics.DrawEllipse($detail, $x - $radius + 2.5, $y - $radius + 2.5, $radius * 2 - 5, $radius * 2 - 5)
    $graphics.FillEllipse($glint, $x - $radius * 0.35, $y - $radius * 0.48, $radius * 0.32, $radius * 0.23)
    $shadow.Dispose(); $rim.Dispose(); $body.Dispose(); $detail.Dispose(); $glint.Dispose()
}

function Draw-Option($option, $outputPath) {
    $bitmap = [System.Drawing.Bitmap]::new(1080, 1920)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $graphics.ScaleTransform(2.0, 2.0)
    $back = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Rectangle]::new(0, 0, 540, 960), [System.Drawing.Color]::FromArgb(255, 29, 7, 44), [System.Drawing.Color]::FromArgb(255, 7, 14, 31), 90.0)
    $graphics.FillRectangle($back, 0, 0, 540, 960)
    $starBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(90, 180, 143, 231))
    $random = [System.Random]::new(82)
    for ($i = 0; $i -lt 95; $i++) {
        $sx = $random.NextDouble() * 540
        $sy = $random.NextDouble() * 960
        $sr = 0.4 + $random.NextDouble() * 1.3
        $graphics.FillEllipse($starBrush, $sx, $sy, $sr, $sr)
    }

    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $points = [System.Drawing.PointF[]]::new(6)
    for ($i = 0; $i -lt 6; $i++) { $points[$i] = [System.Drawing.PointF]::new([float]$option.field_corners[$i][0], [float]$option.field_corners[$i][1]) }
    $path.AddPolygon($points)
    $outerShadow = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(145, 0, 0, 0), 27)
    $outerMetal = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 85, 50, 99), 20)
    $gold = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 166, 103, 139), 11)
    $innerEdge = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 205, 166, 225), 3)
    $floor = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Rectangle]::new(0, 170, 540, 590), [System.Drawing.Color]::FromArgb(255, 45, 28, 67), [System.Drawing.Color]::FromArgb(255, 20, 47, 67), 78.0)
    $graphics.DrawPath($outerShadow, $path)
    $graphics.FillPath($floor, $path)
    $graphics.DrawPath($outerMetal, $path)
    $graphics.DrawPath($gold, $path)
    $graphics.DrawPath($innerEdge, $path)

    $faintOrbit = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(35, 218, 162, 219), 1)
    $graphics.DrawEllipse($faintOrbit, 158, 353, 224, 224)
    $graphics.DrawEllipse($faintOrbit, 194, 389, 152, 152)

    for ($i = 0; $i -lt 4; $i++) {
        $center = $option.side_tower_centers[$i]
        $isBlue = $i -lt 2
        Draw-Disc $graphics ([float]$center[0]) ([float]$center[1]) ([float]$option.side_tower_radius) $isBlue
    }
    for ($i = 0; $i -lt 2; $i++) {
        $center = $option.main_tower_centers[$i]
        Draw-Disc $graphics ([float]$center[0]) ([float]$center[1]) ([float]$option.main_tower_radius) ($i -eq 0)
    }

    $ballShadow = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
    $ballFill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 105, 210, 230))
    $ballRim = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 224, 247, 249), 1.5)
    $graphics.FillEllipse($ballShadow, 252, 450, 39, 39)
    $graphics.FillEllipse($ballFill, 252, 447, 36, 36)
    $graphics.DrawEllipse($ballRim, 252, 447, 36, 36)

    $panel = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(220, 14, 9, 31))
    $text = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 238, 220, 253))
    $subtext = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 175, 192, 219))
    $titleFont = [System.Drawing.Font]::new('Microsoft YaHei', 19, [System.Drawing.FontStyle]::Bold)
    $bodyFont = [System.Drawing.Font]::new('Microsoft YaHei', 11)
    $graphics.FillRectangle($panel, 20, 20, 500, 92)
    $graphics.DrawString(('方案 ' + $option.id + ' · ' + $option.name), $titleFont, $text, 35, 28)
    $graphics.DrawString(('斜边 ' + $option.slope_degrees + '°    副塔 Ø36    主塔 Ø44    球 Ø36'), $bodyFont, $subtext, 35, 68)
    $graphics.FillRectangle($panel, 20, 819, 500, 75)
    $graphics.DrawString(('可玩区域约 ' + [math]::Round($option.playable_area_pixels / 204165 * 100 - 100, 1) + '% 增长 · 边框与塔不设光圈'), $bodyFont, $text, 34, 835)
    $graphics.DrawString('比例图按 540×960 游戏坐标绘制；球体半径保持 18。', $bodyFont, $subtext, 34, 863)

    $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    foreach ($item in @($back, $starBrush, $path, $outerShadow, $outerMetal, $gold, $innerEdge, $floor, $faintOrbit, $ballShadow, $ballFill, $ballRim, $panel, $text, $subtext, $titleFont, $bodyFont, $graphics, $bitmap)) { $item.Dispose() }
}

foreach ($option in $geometry.options) {
    Draw-Option $option (Join-Path $previewRoot ('geometry_' + $option.id + '.png'))
}

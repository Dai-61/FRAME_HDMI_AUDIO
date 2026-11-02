param(
    [Parameter(Mandatory = $true)]
    [string] $InputImage,

    [Parameter(Mandatory = $true)]
    [string] $Destination,

    [ValidateRange(0, 3)]
    [int] $Index = 0
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sourcePath = (Resolve-Path -LiteralPath $InputImage).Path
if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    throw "Target directory does not exist: $Destination"
}

$outputPath = Join-Path $Destination ("IMAGE{0}.BMP" -f $Index)
$source = [System.Drawing.Image]::FromFile($sourcePath)
$canvas = New-Object System.Drawing.Bitmap 640, 480, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)

try {
    $graphics.Clear([System.Drawing.Color]::Black)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    $scale = [Math]::Min(640.0 / $source.Width, 480.0 / $source.Height)
    $drawWidth = [int] [Math]::Round($source.Width * $scale)
    $drawHeight = [int] [Math]::Round($source.Height * $scale)
    $offsetX = [int] ((640 - $drawWidth) / 2)
    $offsetY = [int] ((480 - $drawHeight) / 2)
    $targetRect = New-Object System.Drawing.Rectangle $offsetX, $offsetY, $drawWidth, $drawHeight

    $graphics.DrawImage($source, $targetRect)
    $canvas.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
}
finally {
    $graphics.Dispose()
    $canvas.Dispose()
    $source.Dispose()
}

Write-Host "Created $outputPath (640x480, 24-bit uncompressed BMP)"

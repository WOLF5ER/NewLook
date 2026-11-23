$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$source = Join-Path $PSScriptRoot 'Shelfside.icon.xaml'
$drawing = [Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath $source -Raw))
$drawing.Freeze()

function Render-Icon([int]$size) {
    $visual = New-Object Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    try {
        $scale = $size / 256.0
        $context.PushTransform([Windows.Media.ScaleTransform]::new($scale, $scale))
        $context.DrawDrawing($drawing)
    } finally { $context.Close() }

    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.MemoryStream]::new()
    try {
        $encoder.Save($stream)
        ,$stream.ToArray()
    } finally { $stream.Dispose() }
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$frames = @{}
foreach ($size in $sizes) { $frames[$size] = Render-Icon $size }
$path = Join-Path $PSScriptRoot 'Shelfside.ico'
$writer = [IO.BinaryWriter]::new([IO.File]::Create($path))
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($size in $sizes) {
        $dimension = if ($size -eq 256) { 0 } else { $size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$size].Length)
        $writer.Write([uint32]$offset)
        $offset += $frames[$size].Length
    }
    foreach ($size in $sizes) { $writer.Write([byte[]]$frames[$size]) }
} finally { $writer.Dispose() }

[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'Shelfside-icon.png'), (Render-Icon 512))

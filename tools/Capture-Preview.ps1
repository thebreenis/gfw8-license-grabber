# Render the actual WPF app layout with example account details and no network.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path $PSScriptRoot -Parent
$stage=Join-Path $root 'build\staging'
$window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $stage 'MainWindow.xaml')))
$games=(Get-Content (Join-Path $stage 'backend\games.json') -Raw|ConvertFrom-Json).games
$picker=$window.FindName('GamePicker');$picker.ItemsSource=$games;$picker.SelectedIndex=0
$window.FindName('AccountEmail').Text='player@example.com'
$window.FindName('AccountGamertag').Text='Xbox profile: PlayerOne'
$window.FindName('Activity').Text='Ready. Select a game to get started.'
$window.FindName('ReceiptStatus').Text='No receipt yet'
$view=$window.Content
$view.Measure((New-Object Windows.Size(1320,750)))
$view.Arrange((New-Object Windows.Rect(0,0,1320,750)));$view.UpdateLayout()
$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(1320,750,96,96,[Windows.Media.PixelFormats]::Pbgra32)
$background=New-Object Windows.Media.DrawingVisual
$drawing=$background.RenderOpen()
$drawing.DrawRectangle($window.Background,$null,(New-Object Windows.Rect(0,0,1320,750)))
$drawing.Close();$bitmap.Render($background)
$bitmap.Render($view)
$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$images=Join-Path $root 'docs\images';$null=New-Item -ItemType Directory -Path $images -Force
$path=Join-Path $images 'gfw8-license-grabber.png'
$stream=[IO.File]::Create($path)
try{$encoder.Save($stream)}finally{$stream.Dispose();$window.Close()}
Write-Output 'Rendered app preview using example account details. No account/network requests.'

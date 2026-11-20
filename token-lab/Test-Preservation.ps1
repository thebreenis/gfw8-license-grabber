param([Parameter(Mandatory=$true)][string]$Runtime)
$ErrorActionPreference='Stop'
. (Join-Path $Runtime 'backend\runtime\xbox-auth\TemporaryAuthHelper.ps1')
$fixture=Join-Path $env:TEMP ('GFW8TokenLab-Preservation-'+[guid]::NewGuid().ToString('N'))
$originalLocalAppData=$env:LOCALAPPDATA
try{
 $env:LOCALAPPDATA=$fixture
 $config=[pscustomobject]@{family='Fixture.Game_test'}
 $data=Join-Path $fixture ('Packages\'+$config.family)
 $volatile=@('Settings\settings.dat','Settings\settings.dat.LOG1','Settings\settings.dat.LOG2','Settings\roaming.lock')
 $protected=@('LocalState\save.dat','LocalState\Microsoft.Xbox\pop.bin','Settings\pop.bin','Settings\custom.dat','LocalState\settings.dat','Settings\Nested\settings.dat.LOG1')
 foreach($relative in @($volatile)+@($protected)){
  $path=Join-Path $data $relative
  $null=[IO.Directory]::CreateDirectory((Split-Path $path -Parent))
  [IO.File]::WriteAllText($path,'original fixture')
 }
 $snapshot=@(Get-TemporaryAuthDataSnapshot $config)
 if($snapshot.Count -ne 10){throw 'Snapshot must retain all ten files for backup.'}
 if(@($snapshot|Where-Object windowsSettingsVolatile).Count -ne 4){throw 'Settings exception is too broad or missing.'}
 foreach($relative in $volatile){[IO.File]::Delete((Join-Path $data $relative))}
 Assert-TemporaryAuthDataUnchanged $snapshot
 foreach($relative in $protected){
  $path=Join-Path $data $relative
  [IO.File]::WriteAllText($path,'changed fixture')
  $blocked=$false
  try{Assert-TemporaryAuthDataUnchanged $snapshot}catch{$blocked=$true}
  if(!$blocked){throw ('Changed protected file was accepted: '+$relative)}
  [IO.File]::WriteAllText($path,'original fixture')
  [IO.File]::Delete($path)
  $blocked=$false
  try{Assert-TemporaryAuthDataUnchanged $snapshot}catch{$blocked=$true}
  if(!$blocked){throw ('Missing protected file was accepted: '+$relative)}
  [IO.File]::WriteAllText($path,'original fixture')
 }
 Assert-TemporaryAuthDataUnchanged $snapshot
 Write-Output 'PASS: Windows settings churn tolerated; save/receipt changes and deletions rejected.'
}finally{
 $env:LOCALAPPDATA=$originalLocalAppData
 $resolved=[IO.Path]::GetFullPath($fixture)
 $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
 if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('GFW8TokenLab-Preservation-')){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}

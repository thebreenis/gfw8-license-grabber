# Recovery only for unfinished v1.3 transactions. Never creates a transaction or acquires a token.
function Send-InstalledProgress([double]$Percent,[string]$Text){Send-GuiEvent 'transaction' @{percent=$Percent;text=$Text};Send-GuiLog $Text}
function Save-InstalledJournal($Journal,[string]$Path){
 $temporary=$Path+'.new';[IO.File]::WriteAllText($temporary,($Journal|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($false)))
 if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}
function Copy-InstalledAppData([string]$Source,[string]$Destination){
 if(!(Test-Path -LiteralPath $Source)){return 0}
 $count=0
 foreach($file in Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction Stop){
  if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'App data contains a linked file. No package change will be made.'}
  $relative=$file.FullName.Substring($Source.TrimEnd('\').Length+1);$target=Join-Path $Destination $relative
  $null=[IO.Directory]::CreateDirectory((Split-Path $target -Parent))
  if([IO.File]::Exists($target)){$attributes=[IO.File]::GetAttributes($target);if($attributes -band [IO.FileAttributes]::ReadOnly){[IO.File]::SetAttributes($target,($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))}}
  $input=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try{$mode=if([IO.File]::Exists($target)){[IO.FileMode]::Open}else{[IO.FileMode]::CreateNew};$output=[IO.File]::Open($target,$mode,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$output.SetLength(0);$input.CopyTo($output)}finally{$output.Dispose()}}finally{$input.Dispose();if([IO.File]::Exists($target)){[IO.File]::SetAttributes($target,$file.Attributes)}}
  $count++
 }
 return $count
}
function Restore-InstalledPackage($Journal,[string]$Path){
 if($Journal.restored){return}
 if(!$Journal.changeStarted){$Journal.restored=$true;$Journal.phase='unchanged';Save-InstalledJournal $Journal $Path;return}
 Send-InstalledProgress 82 'Restoring the original game package…'
 $current=@(Get-AppxPackage|Where-Object PackageFamilyName -ceq $Journal.original.family)
 foreach($package in $current){
  if($package.IsDevelopmentMode -and $package.InstallLocation.TrimEnd('\') -ieq $Journal.helperRoot.TrimEnd('\')){
   Initialize-GuiGameHost
   foreach($processId in [InstalledGameHost]::Running($Journal.original.family)){
    $process=Get-Process -Id $processId -ErrorAction SilentlyContinue
    if($process){try{if($process.Path -and $process.Path.StartsWith($Journal.helperRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$process.Kill();$process.WaitForExit()}}finally{$process.Dispose()}}
   }
   Remove-AppxPackage -Package $package.PackageFullName -PreserveApplicationData -ErrorAction Stop
  }elseif($package.PackageFullName -cne $Journal.original.fullName -or $package.InstallLocation.TrimEnd('\') -ine $Journal.original.installLocation.TrimEnd('\')){throw 'Another installation now occupies this identity. Automatic restoration stopped without replacing it.'}
 }
 $originalNow=@(Get-AppxPackage|Where-Object PackageFullName -ceq $Journal.original.fullName)
 if(!$originalNow.Count -or $Journal.phase -notin @('changing','data-restored')){
  Send-InstalledProgress 90 'Restoring retained app data…'
  $null=Copy-InstalledAppData $Journal.retainedData $Journal.original.dataRoot
  $Journal.phase='data-restored';Save-InstalledJournal $Journal $Path
 }
 if(!$originalNow.Count){
  if($Journal.original.development){Add-AppxPackage -Register (Join-Path $Journal.original.installLocation 'AppxManifest.xml') -ErrorAction Stop}
  else{
   $volume=Get-AppxVolume|Where-Object {$Journal.original.installLocation.StartsWith($_.PackageStorePath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1
   if($volume){Add-AppxPackage -Path $Journal.archive -Volume $volume -ErrorAction Stop}else{Add-AppxPackage -Path $Journal.archive -ErrorAction Stop}
  }
 }
 Send-InstalledProgress 94 'Finishing original package registration…'
 $restored=@(Get-AppxPackage|Where-Object PackageFullName -ceq $Journal.original.fullName)
 if($restored.Count -ne 1 -or [bool]$restored[0].IsDevelopmentMode -ne [bool]$Journal.original.development -or $restored[0].InstallLocation.TrimEnd('\') -ine $Journal.original.installLocation.TrimEnd('\')){throw 'Original package registration restoration is not confirmed.'}
 $Journal.restored=$true;$Journal.phase='restored';$Journal.restoredUtc=[DateTime]::UtcNow.ToString('o');Save-InstalledJournal $Journal $Path
 Send-GuiLog 'Original package registration and version restored. Game stayed closed.'
}
function Repair-InstalledTransaction([string]$Path,[switch]$LockHeld){
 $root=[IO.Path]::GetFullPath((Join-Path $script:DataRoot 'PackageRecovery')).TrimEnd('\')+'\'
 $full=[IO.Path]::GetFullPath($Path);if(!$full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery record is outside the app recovery folder.'}
 $journal=Get-Content $full -Raw|ConvertFrom-Json
 # Ordered dictionaries support adding phase fields during recovery after a restart.
 $state=[ordered]@{};foreach($property in $journal.PSObject.Properties){$state[$property.Name]=$property.Value}
 $lock=$null
 try{
  if(!$LockHeld){$lock=New-Object IO.FileStream((Join-Path $script:DataRoot 'installed-auth.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
  Restore-InstalledPackage $state $full
  [pscustomobject]@{packageRestored=$true;message='Original package restored.'}
 }finally{if($lock){$lock.Dispose()}}
}
function Repair-PendingInstalledPackages {
 $root=Join-Path $script:DataRoot 'PackageRecovery';if(!(Test-Path -LiteralPath $root)){return}
 foreach($folder in Get-ChildItem -LiteralPath $root -Directory){
  $path=Join-Path $folder.FullName 'state-private.json';if(!(Test-Path -LiteralPath $path)){continue}
  $journal=Get-Content $path -Raw|ConvertFrom-Json
  if($journal.changeStarted -and !$journal.restored){
   $lock=$null
   try{$lock=New-Object IO.FileStream((Join-Path $script:DataRoot 'installed-auth.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$null=Repair-InstalledTransaction $path -LockHeld}
   catch{$_.Exception.Data['RecoveryPath']=$path;throw}
   finally{if($lock){$lock.Dispose()}}
  }
 }
}

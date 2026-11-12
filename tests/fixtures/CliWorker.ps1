# Synthetic worker used only by Test-CLI.py's separately embedded fixture EXE.
param([string]$RequestPath)
$ErrorActionPreference='Stop'
$request=Get-Content $RequestPath -Raw|ConvertFrom-Json
$job=Split-Path $RequestPath -Parent
$result=[ordered]@{success=$true;data=@{}}
$id=[int]$request.gameId
switch($request.action){
 'receipt' {
  if($id -eq 28){$result.success=$false;$result.unlicensed=$true;$result.message='Fixture: no license.'}
  else{$result.data.receipt=@{gameId=$id;path='[fixture receipt]';proofPath='[fixture proof]';mintedUtc=[DateTimeOffset]::UtcNow.ToString('o');expiresUtc=[DateTimeOffset]::UtcNow.AddHours(24).ToString('o')}}
 }
 'load' {
  if($request.path -like '*cancel-fixture'){$result.data.cancelled=$true}
  else{$result.data.receipt=@{gameId=44;path='[fixture imported receipt]';proofPath='[fixture proof]';mintedUtc=[DateTimeOffset]::UtcNow.ToString('o');expiresUtc=[DateTimeOffset]::UtcNow.AddHours(24).ToString('o')}}
 }
 'token' {
  if($id -eq 2){$result.success=$false;$result.installedBlocked=$true;$result.message='Fixture: installed-game guard.'}
  elseif($id -eq 33){[Console]::Error.WriteLine('PRIVATE_FIXTURE_DIAGNOSTIC');$result.success=$false;$result.message='Fixture: worker failure.'}
  elseif($id -eq 42){$result.success=$false;$result.message='Fixture: duplicate error events.'}
  else{$result.data.token=@{gameId=$id;exportPath='[fixture token]';expiresUtc=[DateTimeOffset]::UtcNow.AddHours(4).ToString('o');gamertag='FixturePlayer'}}
 }
 'presence' {$result.data.presence=@{presenceWriteAccepted=$true;activeReadback=$true;cleanupRequired=$true;cleanupAccepted=$true;targetAbsentAfterCleanup=$true}}
 'availability' {$result.data.installed=($id -eq 2)}
 'bulk' {
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  while(!(Test-Path (Join-Path $job 'cancel.flag')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
  $result.data.bulk=@{checked=1;saved=1;unlicensed=0;errors=0;cancelled=$true};$result.data.run='[fixture batch]'
 }
 default {$result.success=$false;$result.message='Unknown fixture action.'}
}
if(!$result.success -and $id -ne 33){
 $event=@{kind='log';level='error';text=$result.message}|ConvertTo-Json -Compress
 $count=if($id -eq 42){2}else{1}
 @($event)*$count|Set-Content (Join-Path $job 'events.jsonl') -Encoding UTF8
}
$result|ConvertTo-Json -Depth 8|Set-Content (Join-Path $job 'result.json') -Encoding UTF8

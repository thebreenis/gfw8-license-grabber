param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\backend\Core.ps1"
. "$PSScriptRoot\GuiBackend.ps1"
. "$PSScriptRoot\InstalledGames.ps1"
. "$PSScriptRoot\LegacyPackageRecovery.ps1"
Initialize-GuiStorage
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$script:GuiOperation=[string]$request.action
$job=Split-Path ([IO.Path]::GetFullPath($RequestPath)) -Parent
$script:WorkerScratch=$job
$stream=[IO.File]::Open((Join-Path $job 'events.jsonl'),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
$script:EventWriter=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)))
$script:EventWriter.AutoFlush=$true
$script:StoreAccount=[string]$request.storeAccount
$result=[ordered]@{success=$false;action=$request.action}
try{
 $games=@((Get-Content "$PSScriptRoot\backend\games.json" -Raw|ConvertFrom-Json).games)
 $game=$games|Where-Object index -eq ([int]$request.gameId)
 if($request.action -in @('receipt','token','presence','availability') -and !$game){throw 'Choose a supported game.'}
 $data=switch($request.action){
  'account' {Repair-PendingInstalledPackages;Get-GuiAccount;break}
  'receipt' {Get-GuiReceipt $game;break}
  'availability' {[pscustomobject]@{installed=[bool](Get-GuiInstalledPackage $game)};break}
  'packageRecovery' {Repair-InstalledTransaction $request.recoveryPath;break}
  'load' {Import-GuiReceipt $request.path $games;break}
  'token' {Get-GuiToken $game $request.proofPath;break}
  'presence' {Test-GuiPresence $game $request.token;break}
  'bulk' {Get-AllGuiReceipts $games (Join-Path $job 'cancel.flag');break}
  default {throw 'Unknown operation.'}
 }
 $result.success=$true;$result.data=$data
 if($request.action -ne 'availability'){Send-GuiLog $data.message}
}catch{
 if($_.Exception -is [OperationCanceledException]){$result.success=$true;$result.data=[ordered]@{cancelled=$true;message='Cancelled before package changes.'}}else{
 $message=Protect-LogText $_.Exception.Message
 $result.message=$message;$result.errorType=$_.Exception.GetType().Name
 $result.unlicensed=$message.StartsWith('No license for this game/edition')
 $result.installedBlocked=[bool]$_.Exception.Data['InstalledGame']
 if($_.Exception.Data['RecoveryPath'] -or $request.action -eq 'packageRecovery'){$result.restoreRequired=$true;$result.recoveryPath=if($_.Exception.Data['RecoveryPath']){[string]$_.Exception.Data['RecoveryPath']}else{$request.recoveryPath}}
 Send-GuiLog $message 'error'
 }
}finally{
 $result|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $job 'result.json') -Encoding UTF8
 $script:EventWriter.Dispose();$stream.Dispose()
}

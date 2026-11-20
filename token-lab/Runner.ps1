param([string]$Job,[ValidateSet('pull','saved','single')][string]$Mode='saved',[switch]$AllowPrompts,[switch]$DefinitionsOnly)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\backend\Core.ps1"
. "$PSScriptRoot\GuiBackend.ps1"
. "$PSScriptRoot\InstalledGames.ps1"

function Protect-LabText([string]$Text){
 $safe=Protect-LogText $Text
 foreach($path in @($env:USERPROFILE,$PSScriptRoot,$script:LabJob)) {if($path){$safe=$safe.Replace($path,'[private folder]')}}
 if($safe -match '(?i)XBL[23]\.0|WLID1\.0|Bearer\s|<[^>]*(?:token|jwt)|Authorization\s*[:=]'){return '[Credential detail omitted]'}
 $safe=$safe -replace '[A-Za-z]:\\[^\r\n]*','[private diagnostic path]'
 return $safe
}
function Write-LabEvent([string]$Kind,$Fields){
 if(!$script:LabWriter){return}
 $row=[ordered]@{kind=$Kind;utc=[DateTime]::UtcNow.ToString('o')}
 foreach($key in $Fields.Keys){$row[$key]=$Fields[$key]}
 $script:LabWriter.WriteLine(($row|ConvertTo-Json -Compress -Depth 10))
}
# Account events and raw script output never enter the copyable activity log.
function Send-GuiEvent([string]$Kind,$Fields){
 if($Kind -eq 'log'){Write-LabEvent 'log' @{text=(Protect-LabText ([string]$Fields.text));level=$Fields.level}}
 elseif($Kind -eq 'bulk'){Write-LabEvent 'progress' @{phase='Receipts';done=$Fields.done;total=$Fields.total;game=$Fields.game}}
 elseif($Kind -eq 'stage'){Write-LabEvent 'stage' @{text=(Protect-LabText ([string]$Fields.text))}}
}
function Read-LabJson([string]$Path){if(Test-Path -LiteralPath $Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}}
function Get-LabEvidence([string]$Run){
 $report=Read-LabJson (Join-Path $Run 'token-result.json')
 $life=Read-LabJson (Join-Path $Run 'temporary-helper.json')
 $cleanup=if(!$report -and !$life){'Not started'}elseif($report.helperStopped -and $report.privateSessionRemoved -and $life.registrationRemoved -and !$life.cleanupFailureType){'Complete'}else{'UNCONFIRMED'}
 [pscustomobject]@{report=$report;life=$life;cleanup=$cleanup;code=$(if($report.xErr){[string]$report.xErr}elseif($report.helperHresult){[string]$report.helperHresult}else{''})}
}
function Get-LabOutcome([bool]$Issued,[Nullable[int]]$ProfileStatus,$Evidence,[bool]$Installed,[string]$ErrorText){
 if($Installed){return 'Blocked: game installed'}
 if($Evidence.cleanup -eq 'UNCONFIRMED'){return 'Cleanup unconfirmed'}
 if($Evidence.life.dataPreservationFailureType -or $Evidence.life.cleanupFailureType -or $Evidence.report.dataPreservationAlert){return 'Data preservation alert'}
 if($Issued){if($ProfileStatus -eq 200){return 'Valid token'};return 'Issued; profile not verified'}
 if($Evidence.code -ieq '0x8086000C'){return 'Windows sign-in required'}
 if($Evidence.report.stage -eq 'xbox-response' -and $Evidence.report.xErr){return 'Xbox rejected'}
 return 'Token failed'
}
function Save-LabRows($Rows,[string]$Folder){
 # Explicit field list: never serialize token objects, account names, or private reports.
 $public=@($Rows|Select-Object utc,gameId,game,packageFamily,titleId,route,receipt,licenseType,token,code,stage,httpStatus,soapFault,cleanup,profileHttpStatus,message,diagnostics,sdkProfile,sdkSha256,receiptSha256,receiptIdentity,helperHresult,failureType,cleanupFailureType,helperStopped,sessionRemoved,registrationRemoved,faultReason)
 ConvertTo-Json -InputObject $public -Depth 6|Set-Content -LiteralPath (Join-Path $Folder 'results.json') -Encoding UTF8
 $public|Export-Csv -LiteralPath (Join-Path $Folder 'results.csv') -NoTypeInformation -Encoding UTF8
 $failures=@($public|Where-Object {$_.token -notin @('Valid token','Not attempted','No fresh receipt')})
 # Write headers even when there are no failures.
 if($failures.Count){$failures|Export-Csv -LiteralPath (Join-Path $Folder 'token-failures.csv') -NoTypeInformation -Encoding UTF8}
 else{('"utc","gameId","game","packageFamily","titleId","route","receipt","licenseType","token","code","stage","httpStatus","soapFault","cleanup","profileHttpStatus","message","diagnostics","sdkProfile","sdkSha256","receiptSha256","receiptIdentity","helperHresult","failureType","cleanupFailureType","helperStopped","sessionRemoved","registrationRemoved","faultReason"')|Set-Content -LiteralPath (Join-Path $Folder 'token-failures.csv') -Encoding UTF8}
}
function Find-LabSavedReceipts($Games){
 $found=@()
 foreach($game in $Games){
  if($script:LabJob -and (Test-Path -LiteralPath (Join-Path $script:LabJob 'cancel.flag'))){break}
  $dir=Join-Path $script:DataRoot ('Games\'+(Get-GuiFamilyName $game)+'\Receipts')
  if(!(Test-Path -LiteralPath $dir)){continue}
  $best=$null;$bestDate=[DateTimeOffset]::MinValue
  foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter 'receipt-proof-private.json' -Recurse -File)){
   try{$r=Read-TrustedGuiReceipt $file.FullName $game;if($r.Minted -gt $bestDate){$bestDate=$r.Minted;$best=[pscustomobject]@{gameId=$game.index;proofPath=$file.FullName;licenseType=$r.LicenseType}}}catch{}
  }
  if($best){$found+=,$best}
 }
 return $found
}
function Get-LabReceipts($Games,[string]$CancelPath){
 # Let each sequential request finish before starting the next. The shared backend
 # still owns the request mutex, full-scan cooldown and HTTP throttle handling.
 $script:BulkRequestDelayMs=0
 Get-AllGuiReceipts $Games $CancelPath
}
function Invoke-LabBatch {
 param([string]$Folder,[string]$Action,[bool]$Prompts)
 $script:LabJob=$Folder;$cancel=Join-Path $Folder 'cancel.flag'
 $rows=New-Object 'Collections.Generic.List[object]'
 $games=@((Get-Content "$PSScriptRoot\backend\games.json" -Raw|ConvertFrom-Json).games)
 $script:GuiOperation='token'
 $halt='';$entries=@();$completed=0
 try{
  Initialize-GuiStorage
  if($Action -eq 'pull'){
   Write-LabEvent 'log' @{text='Pulling entitled receipts using the main app backend and shared cooldown.';level='info'}
   $bulk=Get-LabReceipts $games $cancel
   foreach($entry in $bulk.bulk.entries){
    if($entry.status -eq 'saved'){
     $entries+=,$entry.receipt;$game=$games|Where-Object index -eq $entry.gameId
     $row=[pscustomobject][ordered]@{utc=[DateTime]::UtcNow.ToString('o');gameId=$game.index;game=$game.name;packageFamily=$game.package_family_name;titleId=$game.legacy_xbox_title_id;route=$game.tokenRoute;receipt='Fresh';licenseType=$entry.receipt.licenseType;token='Not attempted';code='';stage='queued';httpStatus=$null;soapFault=$null;cleanup='Not started';profileHttpStatus=$null;message='Receipt saved. Token test queued.';diagnostics=''}
     $rows.Add($row);Write-LabEvent 'result' @{row=$row}
    }
    else{
     $game=$games|Where-Object index -eq $entry.gameId
     $row=[pscustomobject][ordered]@{utc=[DateTime]::UtcNow.ToString('o');gameId=$game.index;game=$game.name;packageFamily=$game.package_family_name;titleId=$game.legacy_xbox_title_id;route=$game.tokenRoute;receipt=$entry.status;licenseType='';token='Not attempted';code='';stage='receipt';httpStatus=$null;soapFault=$null;cleanup='Not started';profileHttpStatus=$null;message=(Protect-LabText $entry.message);diagnostics=''}
     $rows.Add($row);Write-LabEvent 'result' @{row=$row};Save-LabRows $rows $Folder
    }
   }
   if($bulk.bulk.throttled){$halt='Microsoft throttled receipt requests. Batch stopped; no automatic retries.';return}
  }elseif($Action -eq 'single'){
   $selection=Read-LabJson (Join-Path $Folder 'single-receipt-private.json')
   if(!$selection.path){throw 'Select one receipt file before testing.'}
   Write-LabEvent 'log' @{text='Validating the selected receipt and testing only its game. No Microsoft license requests.';level='info'}
   $imported=Import-GuiReceipt ([string]$selection.path) $games
   $entries=@($imported.receipt)
  }else{
   Write-LabEvent 'log' @{text='Checking the latest valid receipt proofs saved by the app. No Microsoft license requests.';level='info'}
   $entries=@(Find-LabSavedReceipts $games)
   $ids=@($entries|ForEach-Object {[int]$_.gameId})
   foreach($game in $games|Where-Object {[int]$_.index -notin $ids}){
    $row=[pscustomobject][ordered]@{utc=[DateTime]::UtcNow.ToString('o');gameId=$game.index;game=$game.name;packageFamily=$game.package_family_name;titleId=$game.legacy_xbox_title_id;route=$game.tokenRoute;receipt='Missing or expired';licenseType='';token='No fresh receipt';code='';stage='receipt';httpStatus=$null;soapFault=$null;cleanup='Not started';profileHttpStatus=$null;message='No current validated receipt saved by the app.';diagnostics=''}
    $rows.Add($row);Write-LabEvent 'result' @{row=$row}
   }
  }
  foreach($entry in $entries){
   if(Test-Path -LiteralPath $cancel){break}
   $game=$games|Where-Object index -eq ([int]$entry.gameId)
   $row=[pscustomobject][ordered]@{utc=[DateTime]::UtcNow.ToString('o');gameId=$game.index;game=$game.name;packageFamily=$game.package_family_name;titleId=$game.legacy_xbox_title_id;route=$game.tokenRoute;receipt='Fresh';licenseType=$entry.licenseType;token='Token failed';code='';stage='preflight';httpStatus=$null;soapFault=$null;cleanup='Not started';profileHttpStatus=$null;message='';diagnostics=''}
   $run=$null;$issued=$false;$installed=$false;$token=$null;$profileStatus=$null;$errorText=''
   Write-LabEvent 'progress' @{phase='Tokens';done=$completed;total=$entries.Count;game=$game.name}
   try{
    # Main app guard: real installed games are never unregistered or replaced.
    $installed=[bool](Get-GuiInstalledPackage $game)
    Assert-GuiGameUninstalled $game
    $receipt=Read-TrustedGuiReceipt $entry.proofPath $game
    $row.licenseType=$receipt.LicenseType
    $run=New-GuiGameRun $game 'Tokens'
    $row.diagnostics=$run.Substring($script:DataRoot.TrimEnd('\').Length+1)
    $token=Request-GameToken $game $receipt $run -PromptIfNeeded:$Prompts
    $issued=$true
    $auth='XBL2.0 x='+[IO.File]::ReadAllText((Join-Path $token.Export 'issued-token.xml')).Trim()
    try{$profile=Invoke-XboxJson $auth 'https://profile.xboxlive.com/users/me/id';$profileStatus=[int]$profile.Status}finally{$auth=$null}
    if($profileStatus -ne 200){$errorText='Token issued, but read-only Xbox profile validation did not return HTTP 200.'}
   }catch{$errorText=Protect-LabText $_.Exception.Message}
   $evidence=if($run){Get-LabEvidence $run}else{[pscustomobject]@{report=$null;life=$null;cleanup='Not started';code=''}}
   $row.token=Get-LabOutcome $issued $profileStatus $evidence $installed $errorText
   $row.code=$evidence.code;$row.cleanup=$evidence.cleanup;$row.profileHttpStatus=$profileStatus
   if($evidence.report){$row.stage=$evidence.report.stage;$row.httpStatus=$evidence.report.httpStatus;$row.soapFault=$evidence.report.soapFault}
   foreach($field in @('sdkProfile','sdkSha256','receiptSha256','receiptIdentity','helperHresult','helperStopped')){$value=if($evidence.report){$evidence.report.$field}else{$null};$row|Add-Member -NotePropertyName $field -NotePropertyValue $value}
   $row|Add-Member -NotePropertyName sessionRemoved -NotePropertyValue $evidence.report.privateSessionRemoved
   foreach($field in @('failureType','cleanupFailureType','registrationRemoved')){$row|Add-Member -NotePropertyName $field -NotePropertyValue $evidence.life.$field}
   $row|Add-Member -NotePropertyName faultReason -NotePropertyValue (Protect-LabText ((@($evidence.report.faultText) -join ' | ')))
   $row.message=if($errorText){$errorText}else{'Service-issued token with valid expiry; read-only Xbox profile returned HTTP 200.'}
   for($i=$rows.Count-1;$i -ge 0;$i--){if($rows[$i].gameId -eq $row.gameId){$rows.RemoveAt($i)}}
   $rows.Add($row);$completed++;Write-LabEvent 'result' @{row=$row};Save-LabRows $rows $Folder
   Write-LabEvent 'log' @{text=($game.name+': '+$row.token+$(if($row.code){' ('+$row.code+')'})+'; helper cleanup: '+$row.cleanup+'.');level=$(if($row.token -eq 'Valid token'){'info'}else{'error'})}
   # Missing diagnostics after a helper started cannot be treated as safe to continue.
   if($row.cleanup -eq 'UNCONFIRMED' -or ($run -and $row.cleanup -eq 'Not started') -or $row.token -eq 'Data preservation alert'){$halt='Stopped because helper cleanup or game-data preservation could not be confirmed. Inspect this run before retrying.';break}
   $token=$null
  }
 }catch{$halt=Protect-LabText $_.Exception.Message}
 finally{
  Save-LabRows $rows $Folder
  $summary=[ordered]@{version='0.1.3';backendVersion=(Get-Content "$PSScriptRoot\BACKEND_VERSION" -Raw).Trim();finishedUtc=[DateTime]::UtcNow.ToString('o');mode=$Action;catalogueCount=$games.Count;receiptCandidates=$entries.Count;tokensChecked=$completed;validTokens=@($rows|Where-Object token -eq 'Valid token').Count;tokenFailures=@($rows|Where-Object {$_.token -notin @('Valid token','Not attempted','No fresh receipt')}).Count;cancelled=(Test-Path -LiteralPath $cancel);stoppedReason=$halt;presenceRequests=0;achievementRequests=0}
  $summary|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Folder 'summary.json') -Encoding UTF8
  Write-LabEvent 'complete' @{summary=$summary}
 }
}
if($DefinitionsOnly){return}
if(!$Job -or !(Test-Path -LiteralPath $Job -PathType Container)){throw 'A private job directory is required.'}
$script:LabJob=[IO.Path]::GetFullPath($Job)
$stream=[IO.File]::Open((Join-Path $Job 'events.jsonl'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
$script:LabWriter=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)));$script:LabWriter.AutoFlush=$true
try{Invoke-LabBatch $Job $Mode ([bool]$AllowPrompts)}finally{$script:LabWriter.Dispose();$stream.Dispose()}

# Background-worker adapter for the existing receipt/token backend.
function Get-GuiFamilyName($Game){
 $name=[string]$Game.package_family_name
 if(!$name){$name='Game-'+([int]$Game.index).ToString('000')+'-'+[string]$Game.name}
 $name=$name -replace '[^\p{L}\p{N}._ -]','_'
 return $name.Trim().TrimEnd('.')
}
function Ensure-GuiFolder([string]$Path){
 if(!(Test-Path -LiteralPath $Path)){$null=New-PrivateFolder $Path}
 return $Path
}
function New-GuiGameRun($Game,[string]$Category){
 $gamesRoot=Ensure-GuiFolder (Join-Path $script:DataRoot 'Games')
 $familyRoot=Ensure-GuiFolder (Join-Path $gamesRoot (Get-GuiFamilyName $Game))
 $categoryRoot=Ensure-GuiFolder (Join-Path $familyRoot $Category)
 New-PrivateFolder (Join-Path $categoryRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)))
}
function New-PoCRun([int]$GameId){
 $catalog=@((Get-Content (Join-Path $script:Root 'games.json') -Raw|ConvertFrom-Json).games)
 $game=$catalog|Where-Object index -eq $GameId
 if(!$game){throw 'Game metadata unavailable for output folder.'}
 $category=switch($script:GuiOperation){'token'{'Tokens'}'presence'{'Presence'}default{'Receipts'}}
 New-GuiGameRun $game $category
}
function Find-GuiGameByText($Games,[string]$Text,[int]$CurrentId=0,[switch]$Cycle){
 if([string]::IsNullOrEmpty($Text)){return $null}
 $matches=@($Games|Where-Object {$_.name.StartsWith($Text,[StringComparison]::OrdinalIgnoreCase)})
 if(!$matches.Count){$matches=@($Games|Where-Object {$_.name.IndexOf($Text,[StringComparison]::OrdinalIgnoreCase) -ge 0})}
 if(!$matches.Count){return $null}
 if($Cycle){$next=@($matches|Where-Object index -gt $CurrentId);if($next.Count){return $next[0]}}
 return $matches[0]
}
function Initialize-GuiStorage {
 if(!(Test-Path -LiteralPath $script:DataRoot)){$null=New-PrivateFolder $script:DataRoot}
 $acl=[IO.Directory]::GetAccessControl($script:DataRoot)
 if(!$acl.AreAccessRulesProtected){throw 'The private application folder has unexpected permissions.'}
}
function Send-GuiEvent([string]$Kind,$Fields){
 $row=[ordered]@{kind=$Kind;utc=[DateTime]::UtcNow.ToString('o')}
 if($Fields){foreach($key in $Fields.Keys){$row[$key]=$Fields[$key]}}
 if($script:EventWriter){$script:EventWriter.WriteLine(($row|ConvertTo-Json -Compress -Depth 8))}
}
function Protect-LogText([string]$Text){
 $safe=$Text -replace '[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}','[account]'
 $safe=$safe -replace '(?i)xuid\([^)]*\)','xuid(REDACTED)'
 $safe=$safe.Replace($script:DataRoot,'[saved files]')
 if($safe -match '(?i)<jwt\b|WLID1\.0|XBL2\.0|Authorization\s*:'){return '[Credential detail omitted]'}
 return $safe
}
function Send-GuiLog([string]$Text,[string]$Level='info'){
 Send-GuiEvent 'log' @{text=(Protect-LogText $Text);level=$Level}
}
function Set-GuiStage([string]$Text,[double]$Seconds=8){
 Send-GuiEvent 'stage' @{text=$Text;seconds=$Seconds}
}
# Intercept informational backend output; account values travel separately from copyable logs.
$script:OriginalStoreCredential=(Get-Command Get-StoreCredential).ScriptBlock
function Get-StoreCredential {
 if($script:BatchCredential){$credential=[pscustomobject]@{Token=$script:BatchCredential.Token;AccountName=$script:BatchCredential.AccountName;AccountNameAvailable=$script:BatchCredential.AccountNameAvailable}}
 else{$credential=& $script:OriginalStoreCredential}
 $script:StoreAccount=$credential.AccountName
 Send-GuiEvent 'account' @{email=$credential.AccountName}
 return $credential
}
function Write-Host {
 param([Parameter(Position=0,ValueFromRemainingArguments=$true)]$Object,[object]$ForegroundColor,[object]$BackgroundColor,[switch]$NoNewline,[object]$Separator=' ')
 $text=($Object|ForEach-Object {[string]$_}) -join [string]$Separator
 if($text -eq 'Xbox/Store app account switches may not change Windows SSO. This PoC does not switch accounts.'){return}
 if($text -like 'Receipt account*'){Send-GuiLog 'Windows receipt account identified.';return}
 if($text -like 'Xbox token account:*'){
  Send-GuiEvent 'account' @{gamertag=$text.Substring($text.IndexOf(':')+1).Trim()}
  Send-GuiLog 'Xbox profile identified.';return
 }
 if($text -like 'Windows will show sign-in*' -or $text -like 'Complete any Windows sign-in*'){Set-GuiStage 'Windows sign-in, if needed…' 0}
 if($text -like 'Presence readback:*'){Set-GuiStage 'Waiting for Xbox confirmation…' 15}
 if($text -like 'Remove test presence:*' -or $text -like 'Cleanup readback:*'){Set-GuiStage 'Confirming presence cleanup…' 15}
 if($text -like 'Last Played submission:*'){Set-GuiStage 'Submitting Last Played…' 5}
 $level=if([string]$ForegroundColor -eq 'Yellow'){'warning'}elseif([string]$ForegroundColor -eq 'Red'){'error'}else{'info'}
 Send-GuiLog $text $level
}
function Find-ReceiptGame([string]$Path,$Games){
 $settings=New-Object Xml.XmlReaderSettings
 $settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1048576
 $reader=[Xml.XmlReader]::Create([IO.Path]::GetFullPath($Path),$settings)
 $doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null
 try{$doc.Load($reader)}finally{$reader.Dispose()}
 if(@($doc.SelectNodes('/Receipt/AppReceipt')).Count -ne 1){throw 'Expected one application receipt.'}
 $id=$doc.SelectSingleNode('/Receipt/AppReceipt').GetAttribute('AppId')
 $matches=@($Games|Where-Object {$_.package_family_name -ieq $id -or $_.legacy_store_guid -ieq $id})
 if($matches.Count -ne 1){throw 'This receipt does not identify one supported catalogue edition.'}
 return $matches[0]
}
function Save-ReceiptProof($Game,$Receipt,[string]$Origin,[string]$Run){
 $proof=[ordered]@{gameId=[int]$Game.index;path=$Receipt.Path;sha256=$Receipt.Hash;origin=$Origin;signatureVerified=($Origin -eq 'loaded');mintedUtc=$Receipt.Minted.ToString('o');expiresUtc=$Receipt.Expires.ToString('o');storeAccount=$script:StoreAccount}
 $path=Join-Path $Run 'receipt-proof-private.json'
 $proof|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
 [pscustomobject]@{gameId=[int]$Game.index;path=$Receipt.Path;proofPath=$path;origin=$Origin;mintedUtc=$proof.mintedUtc;expiresUtc=$proof.expiresUtc}
}
function Read-TrustedGuiReceipt([string]$ProofPath,$Game){
 $full=[IO.Path]::GetFullPath($ProofPath)
 $root=[IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\')+'\'
 if(!$full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Receipt validation record is outside the private application folder.'}
 $proof=Get-Content -LiteralPath $full -Raw|ConvertFrom-Json
 if($proof.gameId -ne $Game.index -or $proof.origin -notin @('minted','loaded') -or ($proof.origin -eq 'loaded' -and !$proof.signatureVerified)){throw 'Receipt validation record does not match this game.'}
 $receiptPath=[IO.Path]::GetFullPath([string]$proof.path)
 if(!$receiptPath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Saved receipt is outside the private application folder.'}
 if((Get-ResearchFileHash $receiptPath).Hash -ine $proof.sha256){throw 'The saved receipt has changed. Load it again before use.'}
 # A loaded receipt was signature-checked on import; an app-minted receipt came directly from the Store response.
 $script:TrustedReceiptHash=$proof.sha256
 $receipt=Read-Receipt $receiptPath $Game
 if(!$receipt.Valid){throw 'This receipt has expired. Get a new pop.bin before requesting another token.'}
 return $receipt
}
function Import-GuiReceipt([string]$Path,$Games){
 Set-GuiStage 'Checking receipt signature and expiry…' 2
 $game=Find-ReceiptGame $Path $Games
 $script:TrustedReceiptHash=$null
 $receipt=Read-Receipt $Path $game
 if(!$receipt.Valid){throw 'Receipt expired or its timestamp is in the future. It was not loaded.'}
 $run=New-PoCRun $game.index
 $target=Join-Path $run 'pop.bin'
 [IO.File]::WriteAllBytes($target,$receipt.Bytes)
 if((Get-ResearchFileHash $target).Hash -ine $receipt.Hash){throw 'Receipt copy did not match the validated file.'}
 $receipt.Path=$target
 Send-GuiLog 'Microsoft receipt signature verified.'
 Send-GuiLog ($game.name+' selected from receipt XML.')
 Send-GuiLog ('Receipt valid until '+(Format-Time $receipt.Expires)+'.')
 [pscustomobject]@{installed=[bool](Get-GuiInstalledPackage $game);receipt=(Save-ReceiptProof $game $receipt 'loaded' $run);run=$run;message='Receipt loaded'}
}
function Get-GuiReceipt($Game){
 $saved=Get-GuiFreshReceipt $Game
 $saved|Add-Member -NotePropertyName installed -NotePropertyValue ([bool](Get-GuiInstalledPackage $Game))
 return $saved
}
function Get-GuiFreshReceipt($Game){
 Set-GuiStage 'Getting pop.bin…' 7
 $run=New-PoCRun $Game.index
 $receipt=Request-GameReceipt $Game $run
 if(!$receipt.Valid){throw 'The Store returned a receipt outside its 24-hour validity window.'}
 Send-GuiLog ('Receipt issued '+(Format-Time $receipt.Minted)+'.')
 Send-GuiLog ('Receipt expires '+(Format-Time $receipt.Expires)+'.')
 [pscustomobject]@{receipt=(Save-ReceiptProof $Game $receipt 'minted' $run);run=$run;message='Receipt saved'}
}
function Get-TokenProfile([string]$Export){
 $auth='XBL2.0 x='+[IO.File]::ReadAllText((Join-Path $Export 'issued-token.xml')).Trim()
 try{$profile=Invoke-XboxJson $auth 'https://profile.xboxlive.com/users/me/id'}finally{$auth=$null}
 if($profile.Status -ne 200 -or !($profile.Body -is [Collections.IDictionary])){Send-GuiLog ('Token saved; profile lookup returned HTTP '+$profile.Status+'.') 'warning';return $null}
 $tag=[string]$profile.Body['gamertag'];if(!$tag){$tag=[string]$profile.Body['gamerTag']}
 Send-GuiEvent 'account' @{gamertag=$tag}
 Send-GuiLog 'Xbox profile check: HTTP 200.'
 return $tag
}
function Assert-GuiGameUninstalled($Game){
 if(Get-GuiInstalledPackage $Game){$error=New-Object InvalidOperationException('The selected game''s installation interferes with GFW8LG''s ability to grab the token. Please uninstall the selected game and try again. Fresh pop.bin acquisition is still available.');$error.Data['InstalledGame']=$true;throw $error}
}
function Get-GuiToken($Game,[string]$ProofPath){
 Assert-GuiGameUninstalled $Game
 Get-GuiUninstalledToken $Game $ProofPath
}
function Get-GuiUninstalledToken($Game,[string]$ProofPath){
 Assert-GuiGameUninstalled $Game
 $receipt=Read-TrustedGuiReceipt $ProofPath $Game
 $run=New-PoCRun $Game.index
 Set-GuiStage 'Getting Xbox token…' 8
 try{$token=Request-GameToken $Game $receipt $run}
 catch{
  if(!$_.Exception.Data['RequiresReauthentication']){throw}
  Send-GuiLog 'Windows requests verification. Retrying the same receipt with PromptIfNeeded.'
  Set-GuiStage 'Windows sign-in, if needed…' 0
  $run=New-PoCRun $Game.index
  $token=Request-GameToken $Game $receipt $run -PromptIfNeeded
 }
 Set-GuiStage 'Reading Xbox profile…' 3
 $tag=Get-TokenProfile $token.Export
 $dto=[ordered]@{gameId=[int]$Game.index;exportPath=$token.Export;expiresUtc=$token.Window.Expires.ToString('o');issuedUtc=$token.Window.FourHourReference.ToString('o');gamertag=$tag;dataPreservationAlert=[bool]$token.Report.dataPreservationAlert}
 # Cache only our own saved token location for a read-only profile lookup next time; never cache the token value here.
 if($script:StoreAccount){[ordered]@{storeAccount=$script:StoreAccount;exportPath=$token.Export;expiresUtc=$dto.expiresUtc}|ConvertTo-Json|Set-Content (Join-Path $script:DataRoot 'account-cache-private.json') -Encoding UTF8}
 [pscustomobject]@{token=$dto;run=$run;message='Token acquired'}
}
function Test-GuiPresence($Game,$Token){
 Assert-GuiGameUninstalled $Game
 $expiry=[DateTimeOffset]::Parse([string]$Token.expiresUtc)
 if([DateTimeOffset]::UtcNow -ge $expiry){throw 'Token expired. Get another token before testing Presence.'}
 $full=[IO.Path]::GetFullPath([string]$Token.exportPath)
 if(!$full.StartsWith(([IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Token file is outside the private application folder.'}
 $run=New-PoCRun $Game.index
 Set-GuiStage 'Checking Xbox Presence…' 20
 $coreToken=[pscustomobject]@{Export=$full;Window=[pscustomobject]@{Expires=$expiry}}
 $result=Test-GamePresence $Game $coreToken $run
 $message=if($result.presenceWriteAccepted -and $result.activeReadback){'Presence successful'}elseif($result.presenceWriteAccepted){'Write accepted; readback unconfirmed'}else{'Presence test failed'}
 if($result.lastPlayedWriteAccepted){Send-GuiLog 'Last Played submission accepted; profile UI propagation is not verified.'}
 if($result.cleanupRequired -and (!$result.cleanupAccepted -or !$result.targetAbsentAfterCleanup)){Send-GuiLog 'Presence cleanup is not fully confirmed. Review the saved result before testing again.' 'warning';$message+=' — cleanup unconfirmed'}
 [pscustomobject]@{presence=$result;run=$run;message=$message}
}
function Get-GuiAccount {
 Set-GuiStage 'Reading Windows account…' 4
 $credential=Get-StoreCredential;$credential.Token=$null
 $tag=$null;$cachePath=Join-Path $script:DataRoot 'account-cache-private.json'
 if(Test-Path -LiteralPath $cachePath){
  try{
   $cache=Get-Content $cachePath -Raw|ConvertFrom-Json
   $full=[IO.Path]::GetFullPath([string]$cache.exportPath)
   if($cache.storeAccount -eq $credential.AccountName -and [DateTimeOffset]::Parse($cache.expiresUtc) -gt [DateTimeOffset]::UtcNow -and $full.StartsWith(([IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path (Join-Path $full 'issued-token.xml'))){$tag=Get-TokenProfile $full}
  }catch{Send-GuiLog 'Xbox profile will be available after token acquisition.'}
 }
 [pscustomobject]@{email=$credential.AccountName;gamertag=$tag;message='Account information updated'}
}
function Get-AllGuiReceipts($Games,[string]$CancelPath){
 $batches=Ensure-GuiFolder (Join-Path $script:DataRoot 'Batches')
 $batch=New-PrivateFolder (Join-Path $batches ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)))
 Set-GuiStage 'Checking entitled receipts…' 0
 $script:BatchCredential=& $script:OriginalStoreCredential
 $script:StoreAccount=$script:BatchCredential.AccountName
 Send-GuiEvent 'account' @{email=$script:StoreAccount}
 $saved=0;$denied=0;$errors=0;$done=0;$entries=@();$started=[DateTime]::UtcNow
 $staging=New-PrivateFolder (Join-Path $batch 'receipt-staging')
 try{
  foreach($game in $Games){
   if(Test-Path -LiteralPath $CancelPath){break}
   Send-GuiLog ('Checking '+$game.name+'.')
   try{
    $receipt=Request-GameReceipt $game $staging
    if(!$receipt.Valid){throw 'Store receipt is outside its 24-hour validity window.'}
    $run=New-GuiGameRun $game 'Receipts'
    $destination=Join-Path $run 'pop.bin'
    Move-Item -LiteralPath $receipt.Path -Destination $destination -ErrorAction Stop
    $receipt.Path=$destination
    $diagnostic=Join-Path $staging 'receipt-result.json'
    if(Test-Path -LiteralPath $diagnostic){Move-Item -LiteralPath $diagnostic -Destination (Join-Path $run 'receipt-result.json') -ErrorAction Stop}
    $dto=Save-ReceiptProof $game $receipt 'minted' $run
    $saved++;$entries+=,[ordered]@{gameId=$game.index;game=$game.name;status='saved';receipt=$dto}
    Send-GuiLog ($game.name+': receipt saved.')
   }catch{
    if($_.Exception.Message.StartsWith('No license for this game/edition')){$denied++;$state='unlicensed';Send-GuiLog ($game.name+': no entitlement on this account.')}
    else{$errors++;$state='error';Send-GuiLog ($game.name+': '+$_.Exception.Message) 'error'}
    $entries+=,[ordered]@{gameId=$game.index;game=$game.name;status=$state;message=(Protect-LogText $_.Exception.Message)}
   }finally{
    foreach($name in @('pop.bin','receipt-result.json')){
     $temporary=Join-Path $staging $name
     if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop}
    }
   }
   $done++;$remaining=if($done){[Math]::Max(0,[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds/$done*($Games.Count-$done)))}else{0}
   Send-GuiEvent 'bulk' @{done=$done;total=$Games.Count;saved=$saved;unlicensed=$denied;errors=$errors;remainingSeconds=$remaining;game=$game.name}
  }
 }finally{
  $script:BatchCredential.Token=$null;$script:BatchCredential=$null
  if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -ErrorAction Stop}
 }
 $cancelled=($done -lt $Games.Count)
 $summary=[ordered]@{checked=$done;total=$Games.Count;saved=$saved;unlicensed=$denied;errors=$errors;cancelled=$cancelled;entries=$entries}
 $summary|ConvertTo-Json -Depth 10|Set-Content (Join-Path $batch 'bulk-summary-private.json') -Encoding UTF8
 [pscustomobject]@{bulk=$summary;run=$batch;message=$(if($cancelled){'Bulk download cancelled'}else{'Bulk receipt download complete'})}
}

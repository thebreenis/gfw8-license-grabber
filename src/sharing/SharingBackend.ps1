param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\backend\Core.ps1"
. "$PSScriptRoot\GuiBackend.ps1"
. "$PSScriptRoot\InstalledGames.ps1"
Initialize-GuiStorage
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$job=Split-Path ([IO.Path]::GetFullPath($RequestPath)) -Parent
$script:WorkerScratch=$job
$stream=[IO.File]::Open((Join-Path $job 'events-private.jsonl'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
$script:EventWriter=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)))
$script:EventWriter.AutoFlush=$true
$result=[ordered]@{success=$false}
try{
 $games=(Get-Content "$PSScriptRoot\backend\games.json" -Raw|ConvertFrom-Json).games
 if($request.action -eq 'scan'){
  $credential=Get-StoreCredential
  if(!$credential.AccountNameAvailable){$credential.Token=$null;throw 'Windows did not disclose the receipt account. Complete Windows sign-in before scanning.'}
  $script:OriginalStoreCredential={ $credential }.GetNewClosure()
  $script:BulkRequestDelayMs=250
  $data=Get-AllGuiReceipts $games ([string]$request.cancelPath)
  $result.success=$true;$result.data=$data
 }elseif($request.action -eq 'import'){
  $path=Join-Path $job 'received-private.bin'
  $bytes=[Convert]::FromBase64String([string]$request.receipt)
  if($bytes.Length -gt 1048576){throw 'Received receipt is too large.'}
  [IO.File]::WriteAllBytes($path,$bytes)
  $identified=Find-ReceiptGame $path $games
  if([int]$identified.index -ne [int]$request.gameId){throw 'Received receipt belongs to another game.'}
  $data=Import-GuiReceipt $path $games
  $result.success=$true;$result.data=$data
 }elseif($request.action -in @('inventory','receipt')){
  # Silent Windows credential lookup establishes the current receipt account.
  # Credential values remain in this local worker and are never returned.
  $credential=Get-StoreCredential;$currentAccount=$credential.AccountName;$credential.Token=$null
  if(!$credential.AccountNameAvailable){throw 'Windows did not disclose the receipt account. Refresh sign-in before sharing locally acquired games.'}
  $script:StoreAccount=$currentAccount
  $available=@();$proofById=@{};$proofTimeById=@{}
  foreach($game in $games){
   $folder=Join-Path $script:DataRoot ('Games\'+$game.package_family_name+'\Receipts')
   if(!(Test-Path -LiteralPath $folder)){continue}
   $proofFiles=@(Get-ChildItem -LiteralPath $folder -Filter receipt-proof-private.json -File -Recurse|Sort-Object LastWriteTimeUtc -Descending)
   foreach($file in $proofFiles){
    try{
     $proof=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
     if($proof.origin -ne 'minted' -or $proof.storeAccount -ine $currentAccount -or [int]$proof.gameId -ne [int]$game.index){continue}
     $path=[IO.Path]::GetFullPath([string]$proof.path)
     if(!$path.StartsWith(([IO.Path]::GetFullPath($folder).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){continue}
     if((Get-ResearchFileHash $path).Hash -ine $proof.sha256){continue}
     $script:TrustedReceiptHash=$null;$signed=Read-Receipt $path $game
     if(!$signed.SignatureVerified){continue}
     $available+=@([pscustomobject]@{gameId=[int]$game.index;name=$game.name;fresh=[bool]$signed.Valid;expiresUtc=$signed.Expires.ToUniversalTime().ToString('o')})
     $proofById[[int]$game.index]=$signed
     $proofTimeById[[int]$game.index]=$file.LastWriteTimeUtc
     break
    }catch{continue}
   }
  }
  if($request.action -eq 'inventory'){
   $lastScan=$null;$lastHash=$null
   $batches=Join-Path $script:DataRoot 'Batches'
   if(Test-Path -LiteralPath $batches){
    foreach($summaryFile in @(Get-ChildItem -LiteralPath $batches -Filter bulk-summary-private.json -File -Recurse|Sort-Object LastWriteTimeUtc -Descending)){
     try{
      $summary=Get-Content -LiteralPath $summaryFile.FullName -Raw|ConvertFrom-Json
      if($summary.cancelled -or $summary.errors -gt 0 -or $summary.checked -ne $summary.total){continue}
      $account=[string]$summary.storeAccount
      if(!$account){
       $first=@($summary.entries|Where-Object status -eq 'saved'|Select-Object -First 1)
       if(!$first.Count){continue};$proofPath=[IO.Path]::GetFullPath([string]$first[0].receipt.proofPath)
       if(!$proofPath.StartsWith(([IO.Path]::GetFullPath((Join-Path $script:DataRoot 'Games')).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){continue}
       $account=[string](Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json).storeAccount
      }
      if($account -ine $currentAccount){continue}
      # A completed scan supersedes older owned records it explicitly denied.
      # A newer successful individual pull can add a title again without a full scan.
      $deniedIds=@($summary.entries|Where-Object status -eq 'unlicensed'|ForEach-Object {[int]$_.gameId})
      $available=@($available|Where-Object {$_.gameId -notin $deniedIds -or $proofTimeById[[int]$_.gameId] -gt $summaryFile.LastWriteTimeUtc})
      $lastScan=$summaryFile.LastWriteTimeUtc.ToString('o');$lastHash=[string]$summary.catalogueHash;break
     }catch{continue}
    }
   }
   $result.success=$true;$result.data=@{games=@($available);lastScanUtc=$lastScan;lastScanCatalogueHash=$lastHash;currentCatalogueHash=(Get-ResearchFileHash (Join-Path $PSScriptRoot 'backend\games.json')).Hash;totalGames=$games.Count}
  }
  else{
   $id=[int]$request.gameId;$game=$games|Where-Object index -eq $id
   if(!$game -or !$proofById.ContainsKey($id)){throw 'This game has no verified locally acquired entitlement record for the current Windows receipt account. Acquire it locally first.'}
   # Every transfer acquires a new receipt from Microsoft; never fall back to a cached pop.
   # Stage first so failed/denied requests do not create game folders.
   $signed=Request-GameReceipt $game $job
   $script:TrustedReceiptHash=$null;$signed=Read-Receipt $signed.Path $game
   if(!$signed.SignatureVerified -or !$signed.Valid){throw 'The newly requested Store receipt is invalid or outside its 24-hour validity window.'}
   $run=New-GuiGameRun $game 'Receipts';$target=Join-Path $run 'pop.bin'
   Copy-Item -LiteralPath $signed.Path -Destination $target;$signed.Path=$target
   $null=Save-ReceiptProof $game $signed 'minted' $run
   $result.success=$true;$result.data=@{gameId=$id;receipt=[Convert]::ToBase64String($signed.Bytes);expiresUtc=$signed.Expires.ToUniversalTime().ToString('o')}
  }
 }else{throw 'Unsupported sharing operation.'}
}catch{
 $result.message=Protect-LogText $_.Exception.Message
 $result.needsSignIn=($result.message -notlike '*No license*' -and $request.action -ne 'import')
}finally{
 $result|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $job 'result-private.json') -Encoding UTF8
 $script:EventWriter.Dispose();$stream.Dispose()
}

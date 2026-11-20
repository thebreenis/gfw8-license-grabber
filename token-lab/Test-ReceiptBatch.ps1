param([Parameter(Mandatory=$true)][string]$Runtime)
$ErrorActionPreference='Stop'
. (Join-Path $Runtime 'Runner.ps1') -DefinitionsOnly
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
$testRoot=New-PrivateFolder (Join-Path $env:TEMP ('GFW8TokenLab-ReceiptFixture-'+[guid]::NewGuid().ToString('N')))
try{
 # Exercise the real Lab adapter, bulk loop and shared cooldown/throttle functions.
 # Only the credential provider, receipt service and proof-signature boundary are
 # fixtures. No Microsoft requests, real credentials or installed game data.
 $script:OriginalStoreCredential={
  $script:AuthCalls++
  [pscustomobject]@{Token='OFFLINE-FIXTURE';AccountName='fixture@example.invalid';AccountNameAvailable=$true}
 }
 function Start-Sleep {param([int]$Milliseconds) $script:Sleeps++}
 function Save-ReceiptProof($Game,$Receipt,[string]$Source,[string]$Run){
  $proof=Join-Path $Run 'receipt-proof-private.json'
  @{fixture=$true}|ConvertTo-Json|Set-Content -LiteralPath $proof -Encoding UTF8
  [pscustomobject]@{gameId=$Game.index;proofPath=$proof;licenseType=$Receipt.LicenseType}
 }
 function Request-GameReceipt($Game,[string]$Run){
  $script:RequestIds.Add([int]$Game.index)
  $credential=Get-StoreCredential
  Assert ($credential.Token -eq 'OFFLINE-FIXTURE') 'Batch credential was not reused.'
  $credential.Token=$null
  if($Game.index -eq 2){
   if($script:Scenario -eq '429'){Assert-ReceiptResponseAllowed 429 '30'}
   if($script:Scenario -eq '503'){Assert-ReceiptResponseAllowed 503 '1200'}
   throw 'No license for this game/edition on the requesting account: offline fixture.'
  }
  $path=Join-Path $Run 'pop.bin'
  [IO.File]::WriteAllText($path,'OFFLINE-FIXTURE-NOT-A-RECEIPT')
  if($script:Scenario -eq 'cancel'){
   [IO.File]::WriteAllText($script:CancelPath,'')
  }
  [pscustomobject]@{Path=$path;Valid=$true;Minted=[DateTimeOffset]::UtcNow;LicenseType=$(if($Game.index -eq 3){'Trial'}else{'Full'})}
 }
 $games=@(
  [pscustomobject]@{index=1;name='Fixture Full';package_family_name='Fixture.Full'},
  [pscustomobject]@{index=2;name='Fixture Unlicensed';package_family_name='Fixture.Unlicensed'},
  [pscustomobject]@{index=3;name='Fixture Trial';package_family_name='Fixture.Trial'}
 )
 function Reset-Fixture([string]$Scenario){
  $script:Scenario=$Scenario
  $script:DataRoot=New-PrivateFolder (Join-Path $testRoot $Scenario)
  $script:CancelPath=Join-Path $script:DataRoot 'cancel.flag'
  $script:AuthCalls=0;$script:Sleeps=0
  $script:RequestIds=New-Object 'Collections.Generic.List[int]'
 }
 Reset-Fixture 'normal'
 $result=Get-LabReceipts $games $script:CancelPath
 Assert ($result.bulk.checked -eq 3 -and $result.bulk.saved -eq 2 -and $result.bulk.unlicensed -eq 1) 'Normal receipt results changed.'
 Assert (($script:RequestIds -join ',') -eq '1,2,3') 'Receipts were skipped, reordered or retried.'
 Assert ($script:Sleeps -eq 0) 'The faster receipt path still inserted a fixed pause.'
 Assert ($script:AuthCalls -eq 1) 'Windows credentials were requested per game.'
 Assert ($null -eq $script:BatchCredential) 'Batch credential was not released.'
 foreach($entry in @($result.bulk.entries|Where-Object status -eq 'saved')){
  Assert (Test-Path -LiteralPath $entry.receipt.proofPath) 'Saved receipt proof missing.'
  Assert (Test-Path -LiteralPath (Join-Path (Split-Path $entry.receipt.proofPath) 'pop.bin')) 'Saved receipt missing.'
 }
 Assert (!(Test-Path -LiteralPath (Join-Path $script:DataRoot 'Games\Fixture.Unlicensed'))) 'An unlicensed game got an empty folder.'
 $next=Get-FullReceiptScanNext
 Assert ($next -gt [DateTimeOffset]::UtcNow.AddMinutes(14)) 'Shared full-scan cooldown was not retained.'
 $blocked=$false
 try{$null=Get-LabReceipts $games $script:CancelPath}catch{$blocked=$_.Exception.Message -like '*15-minute cooldown*'}
 Assert ($blocked -and $script:RequestIds.Count -eq 3 -and $script:AuthCalls -eq 1) 'Shared full-scan cooldown allowed another scan.'

 foreach($status in @('429','503')){
  Reset-Fixture $status
  $result=Get-LabReceipts $games $script:CancelPath
  Assert ($result.bulk.throttled -and $result.bulk.checked -eq 2) ('HTTP '+$status+' did not stop the receipt batch.')
  Assert (($script:RequestIds -join ',') -eq '1,2') ('HTTP '+$status+' was retried or later games were requested.')
  $minimum=if($status -eq '503'){1198}else{898}
  Assert ((Get-ReceiptCooldown) -ge $minimum) ('HTTP '+$status+' did not retain the shared Retry-After cooldown.')
  Assert ($script:Sleeps -eq 0 -and $script:AuthCalls -eq 1 -and $null -eq $script:BatchCredential) 'Throttle handling changed pacing or credential cleanup.'
 }

 Reset-Fixture 'cancel'
 $result=Get-LabReceipts $games $script:CancelPath
 Assert ($result.bulk.cancelled -and $result.bulk.checked -eq 1 -and $result.bulk.saved -eq 1) 'Cancellation lost the completed receipt or requested later games.'
 Assert (($script:RequestIds -join ',') -eq '1' -and $script:AuthCalls -eq 1 -and $null -eq $script:BatchCredential) 'Cancellation did not stop cleanly between requests.'
 Write-Output 'PASS: sequential receipts without fixed waits, one credential, shared cooldown, 429/503 stop without retry, cancellation and saved/unlicensed outputs (offline fixtures).'
}finally{
 $resolved=[IO.Path]::GetFullPath($testRoot);$expected=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
 if($resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('GFW8TokenLab-ReceiptFixture-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

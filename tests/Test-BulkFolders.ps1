$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bundle=Join-Path $root 'build\staging'
. "$bundle\backend\Core.ps1"
. "$bundle\GuiBackend.ps1"
$script:DataRoot=New-PrivateFolder (Join-Path $root ('build\bulk-fixture-'+[guid]::NewGuid().ToString('N')))
$script:OriginalStoreCredential={ [pscustomobject]@{Token='SYNTHETIC';AccountName='fixture@example.com';AccountNameAvailable=$true} }
$script:cancelOnSuccess=$false
$cancel=Join-Path $script:DataRoot 'cancel.flag'
function Request-GameReceipt($Game,[string]$Run){
 [IO.File]::WriteAllText((Join-Path $Run 'receipt-result.json'),'{"synthetic":true}')
 if($Game.index -eq 2){throw 'No license for this game/edition on the requesting account: SYNTHETIC'}
 if($Game.index -eq 3){throw 'Synthetic network error'}
 if($script:cancelOnSuccess){[IO.File]::WriteAllText($script:cancel,'cancel')}
 $path=Join-Path $Run 'pop.bin';[IO.File]::WriteAllText($path,'SYNTHETIC RECEIPT')
 [pscustomobject]@{Path=$path;Hash='SYNTHETIC';Minted=[DateTimeOffset]::UtcNow;Expires=[DateTimeOffset]::UtcNow.AddHours(24);Valid=($Game.index -ne 5)}
}
$script:cancel=$cancel
$fixture=@(1..5|ForEach-Object {[pscustomobject]@{index=$_;name='Fixture '+$_;package_family_name=('Fixture.Game'+$_)}})
$batch=Get-AllGuiReceipts $fixture $cancel
if($batch.bulk.saved -ne 2 -or $batch.bulk.unlicensed -ne 1 -or $batch.bulk.errors -ne 2){throw 'Bulk accounting mismatch'}
foreach($id in @(2,3,5)){if(Test-Path (Join-Path $script:DataRoot ('Games\Fixture.Game'+$id))){throw 'Failed attempt created a game folder'}}
foreach($entry in $batch.bulk.entries|Where-Object status -eq saved){
 if(!(Test-Path $entry.receipt.path) -or !(Test-Path $entry.receipt.proofPath)){throw 'Successful receipt/proof missing'}
 $proof=Get-Content $entry.receipt.proofPath -Raw|ConvertFrom-Json
 if($proof.path -ne $entry.receipt.path){throw 'Proof still points to staging'}
}
if(Test-Path (Join-Path $batch.run 'receipt-staging')){throw 'Staging leaked'}
if(@($batch.bulk.entries|Where-Object {$_.status -in @('error','unlicensed') -and !$_.message}).Count){throw 'Failed attempt missing batch-log detail'}
$script:cancelOnSuccess=$true
$result=Get-AllGuiReceipts $fixture $cancel
if(!$result.bulk.cancelled -or $result.bulk.checked -ne 1 -or !(Test-Path $result.bulk.entries[0].receipt.path)){throw 'Cancellation lost completed output'}
if(Test-Path (Join-Path $result.run 'receipt-staging')){throw 'Cancelled staging leaked'}
Microsoft.PowerShell.Utility\Write-Output 'PASS: bulk success, denial, network error, invalid receipt and cancellation; no live requests.'

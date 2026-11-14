$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'backend\Core.ps1')
$games=(Get-Content (Join-Path $repo 'backend\games.json') -Raw|ConvertFrom-Json).games
$base='https://licensingwindows.mp.microsoft.com/Licensing/License/AcquireReceipt/6.2/0?productId='
foreach($game in $games){
 $expected=$base+([guid]$game.legacy_store_guid).ToString()+'&receiptType=Full'
 if((Get-ReceiptRequestUri $game) -cne $expected){throw ('Standard request identity changed for '+$game.name)}
}
foreach($name in @('Get-ReceiptRequestUri','Request-GameReceipt','Invoke-GameReceiptRequest')){
 if((Get-Command $name).Parameters.ContainsKey('UsePackageFamilyName')){throw 'Experimental request parameter is still exposed.'}
}
$script:DataRoot=New-PrivateFolder (Join-Path $repo ('build\receipt-request-fixture-'+[guid]::NewGuid().ToString('N')))
try{
 $game=$games|Where-Object index -eq 52
 $script:routes=New-Object 'Collections.Generic.List[string]'
 $script:FailFixture=$false
 function Invoke-GameReceiptRequest($Game,[string]$Run){
  $script:routes.Add((Get-ReceiptRequestUri $Game))
  if($script:FailFixture){throw 'Synthetic standard request failure.'}
  return 'synthetic-standard-success'
 }
 if((Request-GameReceipt $game $script:DataRoot) -ne 'synthetic-standard-success'){throw 'Standard Kinectimals request failed.'}
 $script:FailFixture=$true
 $failed=$false;try{$null=Request-GameReceipt $game $script:DataRoot}catch{$failed=$_.Exception.Message -eq 'Synthetic standard request failure.'}
 if(!$failed -or $script:routes.Count -ne 2){throw 'A failed standard request was retried or changed routes.'}
 $script:FailFixture=$false
 if((Request-GameReceipt $game $script:DataRoot) -ne 'synthetic-standard-success' -or $script:routes.Count -ne 3){throw 'Request lock was not released after failure.'}
 foreach($uri in $script:routes){if($uri -cne ($base+([guid]$game.legacy_store_guid).ToString()+'&receiptType=Full')){throw 'Kinectimals used an unexpected identity.'}}
 Write-Output 'PASS: standard GUID request for all 108 games; experimental parameter removed; Kinectimals single-attempt success/failure and lock cleanup. No live requests.'
}finally{
 $full=[IO.Path]::GetFullPath($script:DataRoot);$parent=[IO.Path]::GetFullPath((Join-Path $repo 'build')).TrimEnd('\')+'\'
 if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf).StartsWith('receipt-request-fixture-')){Remove-Item -LiteralPath $full -Recurse -Force}
}

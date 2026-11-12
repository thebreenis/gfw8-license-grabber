param([string]$SignedReceiptPath)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'backend\Core.ps1')
function Assert-EqualBytes([byte[]]$A,[byte[]]$B,[string]$Name){if([Convert]::ToBase64String($A) -ne [Convert]::ToBase64String($B)){throw $Name};Write-Output ('PASS '+$Name)}
$xml=[Text.Encoding]::UTF8.GetBytes("`r`n<Receipt />`r`n")
Assert-EqualBytes (ConvertTo-GameReceiptBytes ([byte[]](0xEF,0xBB,0xBF)+$xml)) $xml 'remove leading UTF8 BOM and preserve XML whitespace'
Assert-EqualBytes (ConvertTo-GameReceiptBytes $xml) $xml 'preserve BOM-free bytes'
$internal=[byte[]](60,0xEF,0xBB,0xBF,62)
Assert-EqualBytes (ConvertTo-GameReceiptBytes $internal) $internal 'preserve embedded marker bytes'
Assert-EqualBytes (ConvertTo-GameReceiptBytes ([byte[]](0xEF,0xBB))) ([byte[]](0xEF,0xBB)) 'preserve partial marker'
if($SignedReceiptPath){
 $game=((Get-Content (Join-Path $repo 'backend\games.json') -Raw|ConvertFrom-Json).games|Where-Object index -eq 5)
 $before=Read-Receipt $SignedReceiptPath $game
 $folder=New-PrivateFolder (Join-Path $repo ('build\receipt-encoding-'+[guid]::NewGuid().ToString('N')))
 $path=Join-Path $folder 'normalized-private.bin';$bytes=ConvertTo-GameReceiptBytes $before.Bytes
 [IO.File]::WriteAllBytes($path,$bytes);$after=Read-Receipt $path $game
 if(!$before.SignatureVerified -or !$after.SignatureVerified -or $before.AppId -ne $after.AppId -or $before.Minted -ne $after.Minted){throw 'Signed receipt validation changed.'}
 Write-Output 'PASS Microsoft signature, edition and timestamp preserved'
 . (Join-Path $repo 'src\ui\GuiBackend.ps1')
 $script:EncodingScratch=$folder
 function New-PoCRun([int]$GameId){New-PrivateFolder (Join-Path $script:EncodingScratch ([guid]::NewGuid().ToString('N')))}
 function Get-GuiInstalledPackage($Game){return $null}
 $games=(Get-Content (Join-Path $repo 'backend\games.json') -Raw|ConvertFrom-Json).games
 $imported=Import-GuiReceipt $SignedReceiptPath $games
 $saved=[IO.File]::ReadAllBytes($imported.receipt.path)
 Assert-EqualBytes $saved $bytes 'import saves the normalized representation'
 $proof=Get-Content $imported.receipt.proofPath -Raw|ConvertFrom-Json
 if($proof.sha256 -ne (Get-ResearchFileHash $imported.receipt.path).Hash -or !$proof.signatureVerified){throw 'Imported receipt proof hash/signature mismatch.'}
 Write-Output 'PASS imported proof matches normalized receipt hash'
}

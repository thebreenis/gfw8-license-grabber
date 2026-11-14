param([Parameter(Mandatory=$true)][string]$FullReceiptPath,[Parameter(Mandatory=$true)][string]$TrialReceiptPath)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. "$repo\backend\Core.ps1"
. "$repo\src\ui\GuiBackend.ps1"
$games=@((Get-Content "$repo\backend\games.json" -Raw|ConvertFrom-Json).games)
$game=Find-ReceiptGame $TrialReceiptPath $games
$full=Read-Receipt $FullReceiptPath $game;$trial=Read-Receipt $TrialReceiptPath $game
if(!$full.SignatureVerified -or !$trial.SignatureVerified -or $full.LicenseType -ne 'Full' -or $trial.LicenseType -ne 'Trial'){throw 'Real signed receipt classification failed.'}
# Execute the actual independent token driver's validation block, stopping
# before any ticket, helper activation or network operation can occur.
$script:TokenValidationRoot=Join-Path $repo 'backend\runtime\jetpack-auth-investigation'
$driver=[IO.File]::ReadAllText((Join-Path $script:TokenValidationRoot 'Test-XboxExchange.ps1'))
$begin=$driver.IndexOf('$receipt=[IO.File]::ReadAllText');$end=$driver.IndexOf('$ticket=$null;')
if($begin -lt 0 -or $end -le $begin){throw 'Token validation block was not found.'}
$validation=[scriptblock]::Create($driver.Substring($begin,$end-$begin).Replace('$PSScriptRoot','$script:TokenValidationRoot'))
$ExpectedReceiptIdentity=$game.package_family_name
foreach($ReceiptPath in @($FullReceiptPath,$TrialReceiptPath)){$null=& $validation}
$scratch=New-PrivateFolder (Join-Path $repo ('build\trial-storage-fixture-'+[guid]::NewGuid().ToString('N')))
$tampered=Join-Path $scratch 'tampered.bin'
$xml=New-Object Xml.XmlDocument;$xml.PreserveWhitespace=$true;$xml.Load($TrialReceiptPath)
$xml.Receipt.AppReceipt.SetAttribute('LicenseType','Full');[IO.File]::WriteAllText($tampered,$xml.OuterXml)
$rejected=$false;try{$null=Read-Receipt $tampered $game}catch{$rejected=$_.Exception.Message -eq 'Receipt signature invalid.'}
if(!$rejected){throw 'Changing signed Trial to Full was accepted.'}
$xml.Receipt.AppReceipt.SetAttribute('LicenseType','Demo');[IO.File]::WriteAllText($tampered,$xml.OuterXml)
$rejected=$false;try{$null=Read-Receipt $tampered $game}catch{$rejected=$_.Exception.Message -like 'Unsupported receipt license type*'}
if(!$rejected){throw 'Unknown license type was accepted.'}
$script:DataRoot=New-PrivateFolder (Join-Path $scratch 'data');$script:StoreAccount='fixture-account';$script:GuiOperation='receipt'
$script:messages=New-Object 'Collections.Generic.List[string]'
function Send-GuiLog([string]$Text,[string]$Level='info'){$script:messages.Add($Text)}
function Get-GuiInstalledPackage($Game){return $null}
$parent=Ensure-GuiFolder (Join-Path $script:DataRoot ('Games\'+(Get-GuiFamilyName $game)+'\Receipts'))
$oldFull=New-PrivateFolder (Join-Path $parent '20261113-165854-169-6ebe8f7d')
$oldTrial=New-PrivateFolder (Join-Path $parent '20261113-195418-105-6093cc92')
$oldCopy=New-PrivateFolder (Join-Path $parent '20261113-165854-170-6ebe8f7d')
Copy-Item $FullReceiptPath (Join-Path $oldFull 'pop.bin');Copy-Item $TrialReceiptPath (Join-Path $oldTrial 'pop.bin');Copy-Item $FullReceiptPath (Join-Path $oldCopy 'pop.bin')
$fullCopy=Read-Receipt (Join-Path $oldFull 'pop.bin') $game
$dto=Save-ReceiptProof $game $fullCopy 'minted' $oldFull
$batches=Ensure-GuiFolder (Join-Path $script:DataRoot 'Batches');$summary=Join-Path $batches 'bulk-summary-private.json'
@{entries=@(@{receipt=$dto})}|ConvertTo-Json -Depth 8|Set-Content $summary -Encoding UTF8
Initialize-GuiStorage
$map=Get-Content (Join-Path $script:DataRoot 'receipt-folder-map-private.json') -Raw|ConvertFrom-Json
if(!$map.complete -or @($map.folders).Count -ne 3 -or $map.skipped){throw 'Legacy folder migration failed.'}
$migrated=Read-TrustedGuiReceipt $dto.proofPath $game
if($migrated.Hash -ne $full.Hash -or $migrated.LicenseType -ne 'Full'){throw 'Old proof references no longer resolve.'}
$trialPath=Resolve-GuiSavedReceiptPath (Join-Path $oldTrial 'pop.bin')
if((Get-ResearchFileHash $trialPath).Hash -ne $trial.Hash -or (Split-Path (Split-Path $trialPath) -Leaf) -notmatch ' - Trial$'){throw 'Trial migration changed or mislabeled its receipt.'}
$proof=Get-Content (Join-Path (Split-Path $trialPath) 'receipt-proof-private.json') -Raw|ConvertFrom-Json
if($proof.origin -ne 'loaded' -or !$proof.signatureVerified -or $proof.licenseType -ne 'Trial'){throw 'Previously rejected Trial was misclassified as newly acquired ownership.'}
$updated=Get-Content $summary -Raw|ConvertFrom-Json
if(!(Test-Path $updated.entries[0].receipt.path) -or !(Test-Path $updated.entries[0].receipt.proofPath)){throw 'Bulk references were not updated.'}
if(@(Get-ChildItem $parent -Directory|Where-Object Name -like '* (2)').Count -ne 1){throw 'Same-second folder collision was not preserved.'}
$import=Import-GuiReceipt (Join-Path $oldTrial 'pop.bin') $games
if($import.receipt.licenseType -ne 'Trial' -or !(Test-Path $import.receipt.proofPath)){throw 'Signed Trial import failed.'}
$script:TrialSource=$TrialReceiptPath
function Request-GameReceipt($Game,[string]$Run){$p=Join-Path $Run 'pop.bin';Copy-Item $script:TrialSource $p;Read-Receipt $p $Game}
$fresh=Get-GuiFreshReceipt $game
if($fresh.receipt.licenseType -ne 'Trial' -or !(Test-Path $fresh.run) -or (Read-TrustedGuiReceipt $fresh.receipt.proofPath $game).LicenseType -ne 'Trial'){throw 'Fresh Trial was not retained for token use.'}
$script:OriginalStoreCredential={ [pscustomobject]@{Token='SYNTHETIC';AccountName='fixture-account';AccountNameAvailable=$true} }
$bulk=Get-AllGuiReceipts @($game) (Join-Path $scratch 'cancel.flag')
if($bulk.bulk.saved -ne 1 -or $bulk.bulk.entries[0].receipt.licenseType -ne 'Trial'){throw 'Bulk rejected a valid Trial.'}
if(!@($script:messages|Where-Object {$_ -like '*Trial receipt saved*'}).Count){throw 'Trial receipt log label missing.'}
Microsoft.PowerShell.Utility\Write-Output 'PASS: real Microsoft-signed Full/Trial receipts; tamper/type rejection; migration/collisions/old references; Trial import, fresh request and bulk; no network requests.'

$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. "$repo\build\staging\backend\Core.ps1"
. "$repo\src\ui\GuiBackend.ps1"
. "$repo\src\ui\ReceiptInstaller.ps1"
$script:DataRoot=New-PrivateFolder (Join-Path $repo ('build\installer-fixture-'+[guid]::NewGuid().ToString('N')))
$script:fixturePackages=Join-Path $script:DataRoot 'Packages';$source=Join-Path $script:DataRoot 'Input';$null=[IO.Directory]::CreateDirectory($source)
$games=@((Get-Content "$repo\build\staging\backend\games.json" -Raw|ConvertFrom-Json).games|Where-Object index -in @(5,6,26))
function Get-ReceiptInstallerPackages {return @($games|Where-Object index -in @(5,26)|ForEach-Object {[pscustomobject]@{PackageFamilyName=$_.package_family_name}})}
function Get-ReceiptInstallerPackagesRoot {return $script:fixturePackages}
function Test-ReceiptInstallerRunning($Game){return $Game.index -eq 26}
function Read-Receipt([string]$Path,$Game){
 $doc=New-Object Xml.XmlDocument;$doc.Load($Path)
 if($doc.Receipt.FixtureSignature -ne 'VALID'){throw 'Synthetic invalid signature'}
 if($doc.Receipt.AppReceipt.AppId -ine $Game.package_family_name){throw 'Wrong game'}
 $minted=[DateTimeOffset]::Parse($doc.Receipt.ReceiptDate);$window=Get-ReceiptWindow $minted
 [pscustomobject]@{Path=$Path;Bytes=[IO.File]::ReadAllBytes($Path);Hash=(Get-ResearchFileHash $Path).Hash;Minted=$minted;Expires=$window.Expires;Valid=$window.Valid;SignatureVerified=$true}
}
function Save-FixturePop([string]$Directory,$Game,[int]$Minutes,[switch]$Bom,[switch]$Bad){
 $null=[IO.Directory]::CreateDirectory($Directory)
 $text='<Receipt FixtureSignature="'+$(if($Bad){'INVALID'}else{'VALID'})+'" ReceiptDate="'+[DateTimeOffset]::UtcNow.AddMinutes(-$Minutes).ToString('o')+'"><AppReceipt AppId="'+$Game.package_family_name+'" LicenseType="Full" /></Receipt>'
 [IO.File]::WriteAllText((Join-Path $Directory 'pop.bin'),$text,(New-Object Text.UTF8Encoding([bool]$Bom)))
}
$first=$games|Where-Object index -eq 5;$second=$games|Where-Object index -eq 6;$third=$games|Where-Object index -eq 26
Save-FixturePop (Join-Path $source 'a\deep') $first 10 -Bom
Save-FixturePop (Join-Path $source 'b\deep\deeper') $first 3 -Bom
Save-FixturePop (Join-Path $source 'c') $second 4
Save-FixturePop (Join-Path $source 'd') $third 4
Save-FixturePop (Join-Path $source 'expired') $first 1500
Save-FixturePop (Join-Path $source 'bad') $first 4 -Bad
$root=New-PrivateFolder (Join-Path $script:DataRoot 'ReceiptInstaller');$run=New-PrivateFolder (Join-Path $root 'scan')
$plan=New-ReceiptInstallPlan $source $games $run (Join-Path $run 'cancel.flag')
if($plan.entries.Count -ne 3 -or $plan.issues.Count -ne 2 -or $plan.duplicates -ne 1){throw 'Recursive discovery/duplicates/rejections mismatch'}
if(!($plan.entries|Where-Object gameId -eq 5).installed -or ($plan.entries|Where-Object gameId -eq 6).installed){throw 'Installed detection mismatch'}
foreach($row in $plan.entries){if(([IO.File]::ReadAllBytes($row.staged))[0] -ne 60){throw 'Staged receipt has a BOM'}}
$target=Get-ReceiptInstallerDestination $first;Save-FixturePop (Split-Path $target) $first 20 -Bom;$original=[IO.File]::ReadAllBytes($target)
$apply=New-PrivateFolder (Join-Path $root 'apply-installed');$result=Install-ReceiptPlan $plan.planPath $games $false $apply (Join-Path $apply 'cancel.flag')
if($result.installed -ne 1 -or $result.skipped -ne 2 -or $result.errors){throw 'Installed-only filtering/running-game skipping mismatch'}
if(Test-Path -LiteralPath (Join-Path $apply 'backups')){throw 'Installer created unwanted backups'}
if([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -eq [Convert]::ToBase64String($original)){throw 'Existing receipt was not replaced'}
if(([IO.File]::ReadAllBytes($target))[0] -ne 60){throw 'Installed receipt has a BOM'}
if(Test-Path -LiteralPath (Get-ReceiptInstallerDestination $second)){throw 'Uninstalled game was written without opt-in'}
$apply=New-PrivateFolder (Join-Path $root 'apply-all');$result=Install-ReceiptPlan $plan.planPath $games $true $apply (Join-Path $apply 'cancel.flag')
if(!(Test-Path -LiteralPath (Get-ReceiptInstallerDestination $second)) -or $result.errors){throw 'Uninstalled opt-in failed'}
if(($result.entries|Where-Object gameId -eq 5).status -ne 'installed'){throw 'Identical receipt was skipped instead of reinstalled'}
Save-FixturePop (Split-Path $target) $first 1
$newer=(Get-ResearchFileHash $target).Hash;$apply=New-PrivateFolder (Join-Path $root 'newer');$result=Install-ReceiptPlan $plan.planPath $games $true $apply (Join-Path $apply 'cancel.flag')
if((Get-ResearchFileHash $target).Hash -ne $newer -or ($result.entries|Where-Object gameId -eq 5).message -notlike '*newer*'){throw 'Newer installed receipt overwritten'}
$staged=($plan.entries|Where-Object gameId -eq 5).staged;Add-Content -LiteralPath $staged 'tamper';$apply=New-PrivateFolder (Join-Path $root 'tampered');$result=Install-ReceiptPlan $plan.planPath $games $true $apply (Join-Path $apply 'cancel.flag')
if(($result.entries|Where-Object gameId -eq 5).status -ne 'error' -or (Get-ResearchFileHash $target).Hash -ne $newer){throw 'Changed preview was installed'}
foreach($path in @('C:\',$env:WINDIR,(Join-Path $env:WINDIR 'System32'))){$blocked=$false;try{$null=Assert-ReceiptInstallerPath $path -Selection}catch{$blocked=$true};if(!$blocked){throw 'Protected source accepted'}}
$cancelRun=New-PrivateFolder (Join-Path $root 'cancelled');$cancel=Join-Path $cancelRun 'cancel.flag';[IO.File]::WriteAllText($cancel,'cancel');$cancelled=New-ReceiptInstallPlan $source $games $cancelRun $cancel;if(!$cancelled.cancelled -or $cancelled.entries.Count){throw 'Scan cancellation ignored'}
$zipPath=Join-Path $script:DataRoot 'fixture.zip';$zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
try{$entry=$zip.CreateEntry('../../outside/pop.bin');$writer=New-Object IO.StreamWriter($entry.Open());try{$writer.Write([IO.File]::ReadAllText((Join-Path $source 'c\pop.bin')))}finally{$writer.Dispose()}}finally{$zip.Dispose()}
$zipRun=New-PrivateFolder (Join-Path $root 'zip');$zipPlan=New-ReceiptInstallPlan $zipPath $games $zipRun (Join-Path $zipRun 'cancel.flag')
if($zipPlan.entries.Count -ne 1 -or !$zipPlan.entries[0].staged.StartsWith($zipRun) -or (Test-Path (Join-Path $script:DataRoot 'outside'))){throw 'ZIP entry escaped staging'}
$external=Join-Path $script:DataRoot 'External';Save-FixturePop $external $second 4
$link=Join-Path $source 'Linked';$null=New-Item -ItemType Junction -Path $link -Target $external
$linkRun=New-PrivateFolder (Join-Path $root 'links');$linkPlan=New-ReceiptInstallPlan $source $games $linkRun (Join-Path $linkRun 'cancel.flag')
if($linkPlan.found -ne 6){throw 'Scanner followed a junction'}
$sevenPath=Join-Path $script:DataRoot 'receipt archive [1].7z'
$null=Invoke-ReceiptArchiveTool @('a','-t7z','-bd','--',$sevenPath,(Join-Path $source 'c\pop.bin'))
$sevenRun=New-PrivateFolder (Join-Path $root 'seven');$sevenPlan=New-ReceiptInstallPlan $sevenPath $games $sevenRun (Join-Path $sevenRun 'cancel.flag')
if($sevenPlan.entries.Count -ne 1 -or $sevenPlan.issues.Count -ne 0 -or $sevenPlan.entries[0].gameId -ne 6){throw '7z archive was not read correctly'}
Microsoft.PowerShell.Utility\Write-Output 'PASS installer: recursive folder/ZIP/7z, newest per game, BOM normalization, installed opt-in, replacement without backups, running/newer skips, tamper rejection, drive/Windows blocking, cancellation, archive path isolation and junction skip. Synthetic receipts; isolated destinations; no Microsoft requests.'

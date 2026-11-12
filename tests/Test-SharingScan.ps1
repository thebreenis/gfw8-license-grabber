# Isolated real adapter/scan pipeline with synthetic Windows credentials and receipt responses.
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'backend\Core.ps1')
$root=New-PrivateFolder (Join-Path $repo ('build\scan-adapter-fixture-'+[guid]::NewGuid().ToString('N')))
$runtime=Join-Path $root 'runtime';$null=New-Item -ItemType Directory -Path $runtime
Copy-Item (Join-Path $repo 'build\staging\backend') (Join-Path $runtime 'backend') -Recurse
foreach($name in 'GuiBackend.ps1','InstalledGames.ps1'){Copy-Item (Join-Path $repo ('src\ui\'+$name)) (Join-Path $runtime $name)}
Copy-Item (Join-Path $repo 'src\sharing\SharingBackend.ps1') (Join-Path $runtime 'SharingBackend.ps1')
$data=Join-Path $root 'data';$null=New-PrivateFolder $data
$mock=@'

$script:DataRoot='__DATA__'
function Get-StoreCredential {[pscustomobject]@{Token='SYNTHETIC';AccountName='fixture@example.com';AccountNameAvailable=$true}}
function Start-Sleep {param([int]$Milliseconds)}
function Read-Receipt([string]$Path,$Game){
 $fresh=(Split-Path $Path -Leaf) -eq 'new-private.bin'
 [pscustomobject]@{Path=$Path;Bytes=[IO.File]::ReadAllBytes($Path);Hash=(Get-ResearchFileHash $Path).Hash;Minted=[DateTimeOffset]::UtcNow;SignatureVerified=(!$fresh -or $env:GFW8LG_SCAN_FIXTURE -ne 'bad-signature');Valid=(!$fresh -or $env:GFW8LG_SCAN_FIXTURE -ne 'expired');Expires=[DateTimeOffset]::UtcNow.AddHours(24)}
}
$script:fixtureCalls=0
function Request-GameReceipt($Game,[string]$Run){
 $script:fixtureCalls++
 if($env:GFW8LG_SCAN_FIXTURE -in @('fresh','expired','bad-signature')){
  $path=Join-Path $Run 'new-private.bin';[IO.File]::WriteAllText($path,('SYNTHETIC NEW '+[guid]::NewGuid().ToString('N')))
  return Read-Receipt $path $Game
 }
 if($env:GFW8LG_SCAN_FIXTURE -eq 'throttle' -and $script:fixtureCalls -eq 3){$e=New-Object InvalidOperationException('Synthetic429');$e.Data['ReceiptRetryAfterSeconds']=900;throw $e}
 throw 'No license for this game/edition on the requesting account: SYNTHETIC'
}
'@
Add-Content -LiteralPath (Join-Path $runtime 'backend\Core.ps1') -Value ($mock.Replace('__DATA__',$data.Replace("'","''"))) -Encoding UTF8
$savedMode=$env:GFW8LG_SCAN_FIXTURE
try{
 function Invoke-Adapter([string]$Action,[string]$Mode,[switch]$Cancel,[switch]$AllowFailure,[switch]$PreserveCooldown){
  if($Action -eq 'scan' -and !$PreserveCooldown){Remove-Item -LiteralPath (Join-Path $data 'full-scan-cooldown-private.json') -ErrorAction SilentlyContinue}
  $env:GFW8LG_SCAN_FIXTURE=$Mode;$job=New-PrivateFolder (Join-Path $root ([guid]::NewGuid().ToString('N')));$cancelPath=Join-Path $job 'cancel.flag'
  if($Cancel){[IO.File]::WriteAllText($cancelPath,'cancel')}
  @{action=$Action;gameId=5;cancelPath=$cancelPath}|ConvertTo-Json|Set-Content (Join-Path $job 'request-private.json') -Encoding UTF8
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -MTA -ExecutionPolicy Bypass -File (Join-Path $runtime 'SharingBackend.ps1') -RequestPath (Join-Path $job 'request-private.json')
  $r=Get-Content (Join-Path $job 'result-private.json') -Raw|ConvertFrom-Json
  if($AllowFailure){return $r};if(!$r.success){throw ('Fixture adapter failed: '+$r.message)};return $r.data
 }
 $cancelled=Invoke-Adapter scan unlicensed -Cancel
 if(!$cancelled.bulk.cancelled -or $cancelled.bulk.checked -ne 0){throw 'Scan ignored cancellation'}
 $throttled=Invoke-Adapter scan throttle
 if(!$throttled.bulk.throttled -or $throttled.bulk.checked -ne 3){throw 'Scan continued after throttling'}
 $before=Invoke-Adapter inventory unlicensed
 if($before.lastScanUtc){throw 'Partial scan marked catalogue fresh'}
 $catalog=(Get-Content (Join-Path $runtime 'backend\games.json') -Raw|ConvertFrom-Json).games;$game=$catalog|Where-Object index -eq 5
 $seed=Join-Path $data ('Games\'+$game.package_family_name+'\Receipts\synthetic-seed');$null=New-Item -ItemType Directory -Path $seed -Force
 $pop=Join-Path $seed 'pop.bin';[IO.File]::WriteAllText($pop,'SYNTHETIC RECEIPT');$proofFile=Join-Path $seed 'receipt-proof-private.json'
 @{origin='minted';storeAccount='fixture@example.com';gameId=5;path=$pop;sha256=(Get-ResearchFileHash $pop).Hash}|ConvertTo-Json|Set-Content $proofFile -Encoding UTF8
 $complete=Invoke-Adapter scan unlicensed
 if($complete.bulk.checked -ne 108 -or $complete.bulk.errors -ne 0 -or $complete.bulk.saved -ne 0){throw 'Full scan accounting'}
 $blocked=Invoke-Adapter scan unlicensed -AllowFailure -PreserveCooldown
 if($blocked.success -or $blocked.message -notlike '*share a 15-minute cooldown*'){throw 'Common full-scan cooldown did not block a second scan'}
 $inventory=Invoke-Adapter inventory unlicensed
 if(!$inventory.lastScanUtc -or $inventory.lastScanCatalogueHash -ne $inventory.currentCatalogueHash){throw 'Completed scan did not update catalogue freshness'}
 if(@($inventory.games).Count -ne 0){throw 'Full scan denial did not supersede an older owned record'}
 (Get-Item $proofFile).LastWriteTimeUtc=[DateTime]::UtcNow.AddSeconds(2)
 $updated=Invoke-Adapter inventory unlicensed
 if(@($updated.games).Count -ne 1){throw 'Newer successful individual record did not update inventory'}
 if(@(Get-ChildItem (Join-Path $data 'Games') -Directory -ErrorAction SilentlyContinue).Count -ne 1){throw 'Unlicensed scan created game folders beyond the test seed'}
 $first=Invoke-Adapter receipt fresh;$second=Invoke-Adapter receipt fresh
 if($first.receipt -eq $second.receipt -or [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($first.receipt)) -notlike 'SYNTHETIC NEW *'){throw 'Transfer reused an existing receipt instead of acquiring a new one'}
 foreach($mode in 'unlicensed','expired','bad-signature'){
  $failed=Invoke-Adapter receipt $mode -AllowFailure
  if($failed.success -or $failed.data.receipt){throw ('Transfer fell back to a cached receipt after '+$mode)}
 }
 Microsoft.PowerShell.Utility\Write-Output 'PASS sharing freshness: every transfer reacquires; denial, expiry and bad signature fail without cached fallback. Synthetic responses only.'
 Microsoft.PowerShell.Utility\Write-Output 'PASS common bulk/sharing full-scan cooldown; single-game transfers remain separate.'
 Microsoft.PowerShell.Utility\Write-Output 'PASS isolated scan adapter: cancellation, immediate throttle stop, partial-vs-complete freshness, all108 checks, no unlicensed game folders. No Microsoft requests.'
}finally{$env:GFW8LG_SCAN_FIXTURE=$savedMode}

$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. "$repo\build\staging\backend\Core.ps1"
$auth=Join-Path $repo 'build\staging\backend\runtime\xbox-auth'
. (Join-Path $auth 'TemporaryAuthHelper.ps1')
$root=New-PrivateFolder (Join-Path $repo ('build\token-identity-fixture-'+[guid]::NewGuid().ToString('N')))
$games=(Get-Content "$repo\backend\games.json" -Raw|ConvertFrom-Json).games
$receipt=Join-Path $root 'fixture.bin';$checks=0
function Write-IdentityFixture([string]$Identity){[IO.File]::WriteAllText($receipt,('<Receipt><AppReceipt AppId="'+$Identity+'" LicenseType="Full" /></Receipt>'))}
foreach($id in @(5,70,71,72)){
 $game=$games|Where-Object index -eq $id;$config=Get-TemporaryAuthConfig $id
 foreach($identity in @($game.package_family_name,$game.legacy_store_guid)){
  Write-IdentityFixture $identity;$before=(Get-ResearchFileHash $receipt).Hash
  if((Get-TemporaryAuthReceiptIdentity $id $receipt $config) -cne $identity){throw 'Allowed signed identity representation was changed or rejected'}
  if((Get-ResearchFileHash $receipt).Hash -ne $before){throw 'Receipt bytes were rewritten'};$checks++
 }
}
$config=Get-TemporaryAuthConfig 72
foreach($identity in @('2d4168ad-4092-4ea7-92fd-1c81e8191304','unrelated-edition')){
 Write-IdentityFixture $identity;$blocked=$false;try{$null=Get-TemporaryAuthReceiptIdentity 72 $receipt $config}catch{$blocked=$_.Exception.Message -eq 'Receipt belongs to a different game/edition.'};if(!$blocked){throw 'Wrong edition was accepted'};$checks++
}
# Exercise the actual temporary-helper controller with all OS/driver side effects mocked.
$script:SharedHelperRoot=New-PrivateFolder (Join-Path $root 'identity-host')
Copy-Item (Join-Path $auth 'shared-auth-helper\identities.json') $script:SharedHelperRoot
Copy-Item (Join-Path $auth 'shared-auth-helper\manifest-template.xml') $script:SharedHelperRoot
$script:registered=$false;$script:captures=0
function Test-TemporaryAuthReady([int]$GameId){Get-TemporaryAuthConfig $GameId}
function Get-Process {param($Name,$ErrorAction)}
function Get-TemporaryAuthDataSnapshot($Config){}
function Add-AppxPackage {param($Register,$ErrorAction)$script:registered=$true}
function Remove-AppxPackage {param($Package,[switch]$PreserveApplicationData,$ErrorAction)$script:registered=$false}
function Get-AppxPackage {param($Name)if($script:registered){[pscustomobject]@{Name=$config.name;IsDevelopmentMode=$true;InstallLocation=$script:SharedHelperRoot;Version=$config.version;PackageFamilyName=$config.family;PackageFullName='SYNTHETIC'}}}
function Invoke-CapturedAuthDriver($Executable,$Arguments,$Metadata){
 $script:captures++;$index=[Array]::IndexOf($Arguments,'-ExpectedReceiptIdentity')
 if($index -lt 0 -or $Arguments[$index+1] -cne $script:expected){throw 'Controller passed the package PFN instead of the selected receipt identity'}
 $output=$Arguments[[Array]::IndexOf($Arguments,'-OutputPath')+1]
 @{stage='xbox-response';tokenIssued=(!$script:rejectWithSoap);nativeXboxJwt=(!$script:rejectWithSoap);helperStopped=$true;privateSessionRemoved=$true;xErr=$(if($script:rejectWithSoap){'0x8015DA87'}else{$null})}|ConvertTo-Json|Set-Content $output -Encoding UTF8
 [pscustomobject]@{ExitCode=$(if($script:rejectWithSoap){1}else{0})}
}
foreach($identity in @($config.family,'5b34e995-e193-4306-b782-e57c162ea483')){
 $script:expected=$identity;Write-IdentityFixture $identity;$run=New-PrivateFolder (Join-Path $root ([guid]::NewGuid().ToString('N')))
 $life=Invoke-TemporaryXboxAuth -GameId 72 -ReceiptPath $receipt -OutputPath (Join-Path $run 'result.json')
 if(!$life.registrationRemoved -or $script:registered){throw 'Mock controller did not clean up'};$checks++
}
if($script:captures -ne 2){throw 'Controller driver path was not exercised'}
$script:rejectWithSoap=$true;$script:expected='5b34e995-e193-4306-b782-e57c162ea483';Write-IdentityFixture $script:expected
$rejectRun=New-PrivateFolder (Join-Path $root 'soap-rejection');$failureMessage=''
try{$null=Invoke-TemporaryXboxAuth -GameId 72 -ReceiptPath $receipt -OutputPath (Join-Path $rejectRun 'result.json')}catch{$failureMessage=$_.Exception.Message}
$life=Get-Content (Join-Path $rejectRun 'temporary-helper.json') -Raw|ConvertFrom-Json
if($failureMessage -ne 'Xbox rejected the token request (0x8015DA87).' -or !$life.registrationRemoved -or $script:registered){throw 'SOAP rejection was misreported as cleanup failure'};$checks++
function Assert-TemporaryAuthDataUnchanged($Snapshot){throw 'Synthetic settings.dat change'}
$dataRun=New-PrivateFolder (Join-Path $root 'data-change');$failureMessage=''
try{$null=Invoke-TemporaryXboxAuth -GameId 72 -ReceiptPath $receipt -OutputPath (Join-Path $dataRun 'result.json')}catch{$failureMessage=$_.Exception.Message}
$life=Get-Content (Join-Path $dataRun 'temporary-helper.json') -Raw|ConvertFrom-Json
if(!$life.registrationRemoved -or !$life.dataPreservationFailureType -or $life.cleanupFailureType -or !$life.dataPreservationChecked -or $life.dataPreservationVerified){throw 'Data-preservation failure was recorded as a registration cleanup failure'};$checks++
[IO.File]::WriteAllText($receipt,'<Receipt CertificateId="B809E47CD0110A4DB043B3F73E83ACD917FE1336"><AppReceipt AppId="5b34e995-e193-4306-b782-e57c162ea483" LicenseType="Full" /></Receipt>')
$invalidRun=New-PrivateFolder (Join-Path $root 'unsigned-control')
$wrapper=Join-Path $invalidRun 'unsigned-wrapper.ps1'
@'
param($Driver,$Receipt,$SdkRoot,$Output)
function Get-AppxPackage {param($Name)[pscustomobject]@{InstallLocation=$SdkRoot}}
& $Driver -ReceiptPath $Receipt -ExpectedReceiptIdentity '5b34e995-e193-4306-b782-e57c162ea483' -SdkProfile Win81 -PackagedPayload -UseNativeTicket -OutputPath $Output
exit $LASTEXITCODE
'@|Set-Content -LiteralPath $wrapper -Encoding UTF8
$prior=$ErrorActionPreference
try{$ErrorActionPreference='Continue';& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $wrapper -Driver (Join-Path $auth 'AcquireXboxToken.ps1') -Receipt $receipt -SdkRoot (Join-Path $auth 'shared-auth-helper') -Output (Join-Path $invalidRun 'result.json') *> (Join-Path $invalidRun 'driver.log')}finally{$ErrorActionPreference=$prior}
if($LASTEXITCODE -ne 1 -or (Get-Content (Join-Path $invalidRun 'local-error-private.log') -Raw) -notlike '*Expected exactly one receipt signature*'){throw 'Exchange driver did not retain independent signature validation'};$checks++
Microsoft.PowerShell.Utility\Write-Output ('PASS '+$checks+' receipt-identity checks: PFN/GUID forms, wrong-edition rejection, unchanged receipt bytes, exact identity passed by controller and mock cleanup. No real package registration or network calls.')

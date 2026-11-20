param([Parameter(Mandatory=$true)][string]$Runtime)
$ErrorActionPreference='Stop'
. (Join-Path $Runtime 'Runner.ps1') -DefinitionsOnly
function Assert($condition,[string]$message){if(!$condition){throw $message}}
$testRoot=New-PrivateFolder (Join-Path $env:TEMP ('GFW8TokenLab-Fixture-'+[guid]::NewGuid().ToString('N')))
try{
 $script:LabJob=$testRoot
 $safe=Protect-LabText ('Failure at '+$env:USERPROFILE+'\private\worker.ps1 for person@example.com')
 Assert (!$safe.Contains($env:USERPROFILE) -and !$safe.Contains('person@example.com')) 'Path/account redaction failed.'
 Assert ((Protect-LabText 'Authorization: XBL3.0 x=secret') -eq '[Credential detail omitted]') 'Credential redaction failed.'
 $e=[pscustomobject]@{cleanup='Complete';code='0x8015DA87';report=[pscustomobject]@{stage='xbox-response';xErr='0x8015DA87'};life=[pscustomobject]@{}}
 Assert ((Get-LabOutcome $false $null $e $false '') -eq 'Xbox rejected') 'SOAP classification failed.'
 Assert ((Get-LabOutcome $true 200 $e $false '') -eq 'Valid token') 'Validated token classification failed.'
 Assert ((Get-LabOutcome $true 403 $e $false '') -eq 'Issued; profile not verified') 'Profile failure was called valid.'
 $e.cleanup='UNCONFIRMED'
 Assert ((Get-LabOutcome $true 200 $e $false '') -eq 'Cleanup unconfirmed') 'Cleanup failure was called success.'

 # Replace external boundaries with deterministic fixtures. No Microsoft/network calls,
 # package registrations, real receipts or game-data writes occur in these tests.
 $script:DataRoot=$testRoot
 function Initialize-GuiStorage {}
 function Get-AllGuiReceipts($Games,[string]$CancelPath){[pscustomobject]@{bulk=[pscustomobject]@{throttled=$false;entries=@([pscustomobject]@{gameId=1;status='saved';receipt=[pscustomobject]@{gameId=1;proofPath='fixture-1'}},[pscustomobject]@{gameId=2;status='saved';receipt=[pscustomobject]@{gameId=2;proofPath='fixture-2'}},[pscustomobject]@{gameId=3;status='unlicensed';message='No entitlement'})}}}
 function Get-GuiInstalledPackage($Game){return $null}
 function Assert-GuiGameUninstalled($Game){}
 function Read-TrustedGuiReceipt([string]$Path,$Game){[pscustomobject]@{Path='fixture';Hash='fixture';LicenseType='Trial'}}
 function New-GuiGameRun($Game,[string]$Category){New-PrivateFolder (Join-Path $script:DataRoot ('game-'+$Game.index+'-'+[guid]::NewGuid().ToString('N')))}
 $script:FixtureCalls=0;$script:UnsafeFixture=$false;$script:CancelDuringFixture=$false
 function Request-GameToken($Game,$Receipt,[string]$Run,[switch]$PromptIfNeeded){
  $script:FixtureCalls++
  $report=@{helperStopped=$true;privateSessionRemoved=$true;stage='xbox-response';httpStatus=200;soapFault=($Game.index -eq 1);xErr=$(if($Game.index -eq 1){'0x8015DA87'}else{''})}
  $life=@{registrationRemoved=(!$script:UnsafeFixture)}
  $report|ConvertTo-Json|Set-Content (Join-Path $Run 'token-result.json')
  $life|ConvertTo-Json|Set-Content (Join-Path $Run 'temporary-helper.json')
  if($script:CancelDuringFixture){[IO.File]::WriteAllText((Join-Path $script:LabJob 'cancel.flag'),'')}
  if($Game.index -eq 1){throw 'Xbox rejected fixture request (0x8015DA87).'}
  [IO.File]::WriteAllText((Join-Path $Run 'issued-token.xml'),'NOT-A-REAL-TOKEN')
  [pscustomobject]@{Export=$Run}
 }
 function Invoke-XboxJson([string]$Auth,[string]$Url){[pscustomobject]@{Status=200}}
 $batch=New-PrivateFolder (Join-Path $testRoot 'batch')
 Invoke-LabBatch $batch 'pull' $false
 $result=Get-Content (Join-Path $batch 'results.json') -Raw|ConvertFrom-Json
 Assert ($result.Count -eq 3) ('Batch did not preserve receipt failures and token outcomes: '+(Get-Content (Join-Path $batch 'summary.json') -Raw)+' Results: '+($result|ConvertTo-Json -Compress -Depth 6))
 Assert (@($result|Where-Object token -eq 'Valid token').Count -eq 1) 'Success count incorrect.'
 Assert (@(Import-Csv (Join-Path $batch 'token-failures.csv')).Count -eq 1) 'Token failure CSV includes wrong results.'
 $summary=Get-Content (Join-Path $batch 'summary.json') -Raw|ConvertFrom-Json
 Assert ($summary.tokensChecked -eq 2 -and $summary.presenceRequests -eq 0 -and $summary.achievementRequests -eq 0) 'Batch summary incorrect.'
 # Single-file mode must import exactly the selected receipt, not scan all games.
 function Import-GuiReceipt([string]$Path,$Games){
  Assert ($Path -eq 'selected-fixture.bin') 'Single receipt selection was not forwarded.'
  [pscustomobject]@{receipt=[pscustomobject]@{gameId=2;proofPath='fixture-2';licenseType='Trial'}}
 }
 $script:FixtureCalls=0
 $singleBatch=New-PrivateFolder (Join-Path $testRoot 'single')
 @{path='selected-fixture.bin'}|ConvertTo-Json|Set-Content (Join-Path $singleBatch 'single-receipt-private.json')
 Invoke-LabBatch $singleBatch 'single' $false
 $singleRows=@(Get-Content (Join-Path $singleBatch 'results.json') -Raw|ConvertFrom-Json)
 Assert ($script:FixtureCalls -eq 1 -and $singleRows.Count -eq 1 -and $singleRows[0].gameId -eq 2) 'Single mode tested additional games.'
 Assert ($singleRows[0].licenseType -eq 'Trial') 'Trial/Full type missing from single report.'
 $singleCsv=Import-Csv (Join-Path $singleBatch 'results.csv')
 Assert ($singleCsv.licenseType -eq 'Trial') 'Trial/Full column missing from CSV.'
 # A stop requested during one token attempt still records its completed cleanup,
 # then prevents the next token attempt. It must not discard completed evidence.
 $script:CancelDuringFixture=$true;$script:FixtureCalls=0
 $stoppingBatch=New-PrivateFolder (Join-Path $testRoot 'stop-during-token')
 Invoke-LabBatch $stoppingBatch 'pull' $false
 $stoppingSummary=Get-Content (Join-Path $stoppingBatch 'summary.json') -Raw|ConvertFrom-Json
 $stoppingRows=Get-Content (Join-Path $stoppingBatch 'results.json') -Raw|ConvertFrom-Json
 Assert ($script:FixtureCalls -eq 1 -and $stoppingSummary.cancelled -and $stoppingSummary.tokensChecked -eq 1) 'Mid-operation stop requested another token.'
 Assert (@($stoppingRows|Where-Object cleanup -eq 'Complete').Count -eq 1) 'Mid-operation stop lost the current cleanup result.'
 $script:CancelDuringFixture=$false
 $script:UnsafeFixture=$true;$script:FixtureCalls=0
 $batch=New-PrivateFolder (Join-Path $testRoot 'unsafe')
 Invoke-LabBatch $batch 'pull' $false
 $summary=Get-Content (Join-Path $batch 'summary.json') -Raw|ConvertFrom-Json
 Assert ($script:FixtureCalls -eq 1 -and !!$summary.stoppedReason) 'Unconfirmed cleanup did not halt the batch.'
 $script:FixtureCalls=0
 $batch=New-PrivateFolder (Join-Path $testRoot 'cancelled')
 [IO.File]::WriteAllText((Join-Path $batch 'cancel.flag'),'')
 Invoke-LabBatch $batch 'pull' $false
 Assert ($script:FixtureCalls -eq 0) 'Cancellation did not prevent token requests.'
 Write-Output 'PASS: redaction, token/profile classification, reports, cleanup halt, cancellation (offline fixtures).'
}finally{
 $resolved=[IO.Path]::GetFullPath($testRoot);$expected=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
 if($resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('GFW8TokenLab-Fixture-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

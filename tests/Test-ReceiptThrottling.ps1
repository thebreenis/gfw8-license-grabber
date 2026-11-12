$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'backend\Core.ps1')
$script:DataRoot=New-PrivateFolder (Join-Path $repo ('build\throttle-fixture-'+[guid]::NewGuid().ToString('N')))
if((Get-ReceiptRetryDelay '120') -ne 120){throw 'Retry-After seconds'}
$future=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('R');$delay=Get-ReceiptRetryDelay $future
if($delay -lt 295 -or $delay -gt 300){throw 'Retry-After date'}
Assert-ReceiptResponseAllowed 200 ''
$blocked=$false;try{Assert-ReceiptResponseAllowed 429 '1800'}catch{$blocked=$_.Exception.Data['ReceiptRetryAfterSeconds'] -eq 1800}
if(!$blocked -or (Get-ReceiptCooldown) -lt 1795){throw 'Throttling did not persist Retry-After'}
$script:networkCalls=0
function Invoke-GameReceiptRequest($Game,[string]$Run){$script:networkCalls++;return 'synthetic-response'}
try{Request-GameReceipt $null $script:DataRoot}catch{}
if($script:networkCalls -ne 0){throw 'Cooldown allowed another network request'}
@{untilUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $script:DataRoot 'receipt-cooldown-private.json') -Encoding UTF8
if((Request-GameReceipt $null $script:DataRoot) -ne 'synthetic-response' -or $script:networkCalls -ne 1){throw 'Expired cooldown did not release request'}
Microsoft.PowerShell.Utility\Write-Output 'PASS Retry-After seconds/date, persisted backoff, no request during cooldown, and recovery after expiry. No network calls.'

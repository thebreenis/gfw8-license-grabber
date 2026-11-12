param([Parameter(Mandatory=$true)][string]$RuntimeRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RuntimeRoot 'backend\Core.ps1')
$catalog=(Get-Content (Join-Path $RuntimeRoot 'backend\games.json') -Raw|ConvertFrom-Json).games
$game=$catalog|Where-Object index -eq 26
$scratch=New-PrivateFolder (Join-Path $PSScriptRoot ('..\build\sharing-validation-'+[guid]::NewGuid().ToString('N')))
$before=@(Get-ChildItem (Join-Path $script:DataRoot 'Games') -Filter receipt-proof-private.json -File -Recurse).Count
function Invoke-ImportTest([string]$Xml,[int]$GameId,[string]$Name){
 $job=New-PrivateFolder (Join-Path $scratch $Name)
 @{action='import';gameId=$GameId;receipt=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Xml))}|ConvertTo-Json|Set-Content (Join-Path $job 'request-private.json') -Encoding UTF8
 & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -MTA -ExecutionPolicy Bypass -File (Join-Path $RuntimeRoot 'SharingBackend.ps1') -RequestPath (Join-Path $job 'request-private.json')
 $result=Get-Content (Join-Path $job 'result-private.json') -Raw|ConvertFrom-Json
 if($result.success){throw ('Accepted invalid receipt: '+$Name)}
 Write-Output ('PASS '+$Name)
}
$unsigned='<Receipt CertificateId="B809E47CD0110A4DB043B3F73E83ACD917FE1336" ReceiptDate="'+[DateTimeOffset]::UtcNow.ToString('o')+'"><AppReceipt AppId="'+$game.package_family_name+'" LicenseType="Full" /></Receipt>'
Invoke-ImportTest $unsigned 26 'unsigned receipt rejected'
Invoke-ImportTest $unsigned 27 'different game rejected'
Invoke-ImportTest '<!DOCTYPE Receipt [<!ENTITY x SYSTEM "file:///C:/Windows/win.ini">]><Receipt>&x;</Receipt>' 26 'XML external entity rejected'
$proof=Get-ChildItem (Join-Path $script:DataRoot 'Games') -Filter receipt-proof-private.json -File -Recurse|Select-Object -First 1
$record=Get-Content $proof.FullName -Raw|ConvertFrom-Json
$xml=New-Object Xml.XmlDocument;$xml.PreserveWhitespace=$true;$xml.XmlResolver=$null;$xml.Load([string]$record.path)
$xml.DocumentElement.SetAttribute('ReceiptDate',[DateTimeOffset]::UtcNow.ToString('o'))
Invoke-ImportTest $xml.OuterXml ([int]$record.gameId) 'tampered signed receipt rejected'
$after=@(Get-ChildItem (Join-Path $script:DataRoot 'Games') -Filter receipt-proof-private.json -File -Recurse).Count
if($before -ne $after){throw 'Invalid imports created a game receipt record.'}
Write-Output 'PASS invalid imports create no game receipt records'

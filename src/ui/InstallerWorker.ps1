param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\backend\Core.ps1"
. "$PSScriptRoot\GuiBackend.ps1"
. "$PSScriptRoot\ReceiptInstaller.ps1"
$job=Split-Path ([IO.Path]::GetFullPath($RequestPath)) -Parent
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$result=@{success=$false}
try{
 Add-Type -Path (Join-Path $PSScriptRoot 'InstalledGameHost.cs')
 $games=(Get-Content -LiteralPath "$PSScriptRoot\backend\games.json" -Raw|ConvertFrom-Json).games
 $data=switch($request.action){
  'scan' {New-ReceiptInstallPlan $request.source $games $job (Join-Path $job 'cancel.flag');break}
  'install' {Install-ReceiptPlan $request.planPath $games ([bool]$request.includeUninstalled) $job (Join-Path $job 'cancel.flag');break}
  default {throw 'Unknown installer operation.'}
 }
 $result.success=$true;$result.data=$data
}catch{$result.message=$_.Exception.Message}
$result|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $job 'result-private.json') -Encoding UTF8

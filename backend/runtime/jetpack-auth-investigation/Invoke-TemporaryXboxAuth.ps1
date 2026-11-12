param([Parameter(Mandatory=$true)][ValidateRange(1,108)][int]$GameId,[Parameter(Mandatory=$true)][string]$ReceiptPath,[Parameter(Mandatory=$true)][string]$OutputPath,[switch]$Reauthenticate,[switch]$PromptIfNeeded,[string]$PrivateTokenOutputDirectory,[switch]$InjectFailureAfterRegistration)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/TemporaryAuthHelper.ps1"
try{
 $null=Invoke-TemporaryXboxAuth -GameId $GameId -ReceiptPath $ReceiptPath -OutputPath $OutputPath -Reauthenticate:$Reauthenticate -PromptIfNeeded:$PromptIfNeeded -PrivateTokenOutputDirectory $PrivateTokenOutputDirectory -InjectFailureAfterRegistration:$InjectFailureAfterRegistration
 if(Test-Path -LiteralPath $OutputPath){Get-Content -LiteralPath $OutputPath -Raw}
 exit 0
}catch{
 if(Test-Path -LiteralPath $OutputPath){Get-Content -LiteralPath $OutputPath -Raw}
 Write-Error $_.Exception.Message -ErrorAction Continue
 exit 1
}

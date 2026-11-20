$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$auth = Join-Path $repo 'backend\runtime\jetpack-auth-investigation'
. (Join-Path $auth 'TemporaryAuthHelper.ps1')

$missing = Get-TemporaryAuthConfig 72
$owned = Get-TemporaryAuthConfig 71
$script:mockPackages = @(
    [pscustomobject]@{ Name = $missing.name; IsDevelopmentMode = $true; InstallLocation = $null },
    [pscustomobject]@{ Name = $owned.name; IsDevelopmentMode = $true; InstallLocation = $script:SharedHelperRoot },
    [pscustomobject]@{ Name = 'Unrelated.Package'; IsDevelopmentMode = $true; InstallLocation = $script:SharedHelperRoot }
)
function Get-AppxPackage {
    param([string]$Name)
    if ($Name) { $script:mockPackages | Where-Object Name -eq $Name }
    else { $script:mockPackages }
}

$registrations = @(Get-TemporaryAuthRegistrations)
if ($registrations.Count -ne 1 -or $registrations[0].Name -ne $owned.name) {
    throw 'Null-location package was counted as a shared helper, or owned helper was missed.'
}
$blocked = $false
try { $null = Test-TemporaryAuthReady 72 }
catch { $blocked = $_.Exception.Message -eq 'A real game or another helper occupies a target identity. No package will be replaced.' }
if (-not $blocked) { throw 'Null-location target was not treated as an occupied identity.' }

Microsoft.PowerShell.Utility\Write-Output 'PASS null InstallLocation is skipped during helper scan and blocked as a target identity.'

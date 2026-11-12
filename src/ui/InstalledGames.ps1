# Read-only installed-game detection. No registration or receipt-file changes.
function Get-GuiInstalledPackage($Game){
 $matches=@(Get-AppxPackage | Where-Object {$_.PackageFamilyName -ieq $Game.package_family_name})
 if($matches.Count -gt 1){throw 'Multiple matching installations found. Resolve the package selection before continuing.'}
 if(!$matches.Count){return $null}
 $package=$matches[0]
 [pscustomobject]@{family=$package.PackageFamilyName;fullName=$package.PackageFullName;version=[string]$package.Version;installLocation=$package.InstallLocation;dataRoot=(Join-Path $env:LOCALAPPDATA ('Packages\'+$package.PackageFamilyName));gameId=[int]$Game.index;gameName=$Game.name}
}
function Initialize-GuiGameHost {if(!('InstalledGameHost' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'InstalledGameHost.cs')}}
function Get-GuiRunningGame($Installation){Initialize-GuiGameHost;return @([InstalledGameHost]::Running($Installation.family))}

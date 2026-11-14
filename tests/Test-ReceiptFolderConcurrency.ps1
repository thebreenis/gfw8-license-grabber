$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. "$repo\backend\Core.ps1"
. "$repo\src\ui\GuiBackend.ps1"
$data=New-PrivateFolder (Join-Path $repo ('build\concurrent-receipts-'+[guid]::NewGuid().ToString('N')))
$parent=New-PrivateFolder (Join-Path $data 'Receipts')
$jobs=@(1..4|ForEach-Object {Start-Job -ArgumentList $repo,$parent -ScriptBlock {
 param($repo,$parent)
 $ErrorActionPreference='Stop'
 . "$repo\backend\Core.ps1"
 . "$repo\src\ui\GuiBackend.ps1"
 New-GuiOutputFolder $parent '2026-11-13 20-54-18 - Trial'
}})
try{
 $null=$jobs|Wait-Job -Timeout 40
 if(@($jobs|Where-Object State -ne Completed).Count){throw 'Concurrent receipt save did not complete.'}
 $paths=@($jobs|Receive-Job -ErrorAction Stop)
 if($paths.Count -ne 4 -or @($paths|Sort-Object -Unique).Count -ne 4){throw 'Concurrent saves reused a receipt folder.'}
 foreach($path in $paths){if(!(Test-Path -LiteralPath $path -PathType Container)){throw 'A reserved output folder is missing.'}}
 Write-Output 'PASS: four independent workers saving the same receipt timestamp get four distinct folders.'
}finally{$jobs|Remove-Job -Force}

# Local-only receipt discovery and installation. Never requests Store/Xbox credentials.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
. "$PSScriptRoot\ReceiptArchives.ps1"
function Assert-ReceiptInstallerPath([string]$Path,[switch]$Selection){
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
 $windows=[IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\')
 if(!$full -or $full -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Choose a folder inside the drive, not a drive root.'}
 if($full -ieq $windows -or $full.StartsWith($windows+'\',[StringComparison]::OrdinalIgnoreCase) -or $full -match '^C:\\Windows(?:\\|$)'){throw 'Windows folders cannot be scanned or used as receipt destinations.'}
 $cursor=$full
 while($cursor -and $cursor -ne [IO.Path]::GetPathRoot($cursor)){
  if(Test-Path -LiteralPath $cursor){if(([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked folders and files are skipped to keep receipts inside the selected locations.'}}
  $cursor=[IO.Path]::GetDirectoryName($cursor)
 }
 return $full
}
function Get-ReceiptInstallerPackages {return @(Get-AppxPackage)}
function Get-ReceiptInstallerPackagesRoot {return Join-Path $env:LOCALAPPDATA 'Packages'}
function Test-ReceiptInstallerRunning($Game){
 if(!('InstalledGameHost' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'InstalledGameHost.cs')}
 return @([InstalledGameHost]::Running([string]$Game.package_family_name)).Count -gt 0
}
function Get-ReceiptInstallerDestination($Game){
 $root=[IO.Path]::GetFullPath((Get-ReceiptInstallerPackagesRoot)).TrimEnd('\')+'\'
 $path=[IO.Path]::GetFullPath((Join-Path $root ($Game.package_family_name+'\LocalState\Microsoft.Xbox\pop.bin')))
 if(!$path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Receipt destination is outside the current user package folder.'}
 $null=Assert-ReceiptInstallerPath $path
 return $path
}
function New-ReceiptInstallPlan([string]$Source,$Games,[string]$Run,[string]$CancelPath){
 $source=Assert-ReceiptInstallerPath $Source -Selection
 $null=Ensure-GuiFolder $Run
 $staging=Ensure-GuiFolder (Join-Path $Run 'receipts')
 $packages=@(Get-ReceiptInstallerPackages);$best=@{};$issues=New-Object Collections.Generic.List[object];$cancelled=$false
 function Inspect-InstallerReceipt([byte[]]$Bytes,[string]$Origin){
  $script:InstallerFound++
  $staged=Join-Path $staging ([guid]::NewGuid().ToString('N')+'.bin')
  try{
   if($Bytes.Length -gt 1048576){throw 'Receipt exceeds the 1 MB limit.'}
   [IO.File]::WriteAllBytes($staged,(ConvertTo-GameReceiptBytes $Bytes))
   $game=Find-ReceiptGame $staged $Games;$script:TrustedReceiptHash=$null;$receipt=Read-Receipt $staged $game
   if(!$receipt.SignatureVerified -or !$receipt.Valid){throw 'Receipt expired, has a future date, or has an invalid signature.'}
   $id=[int]$game.index
   if($best.ContainsKey($id)){$script:InstallerDuplicates++}
   $row=[pscustomobject]@{gameId=$id;game=($game.name+$(if($receipt.LicenseType -eq 'Trial'){' [Trial]'}else{''}));licenseType=$receipt.LicenseType;family=$game.package_family_name;installed=[bool]@($packages|Where-Object PackageFamilyName -ieq $game.package_family_name).Count;mintedUtc=$receipt.Minted.ToString('o');expiresUtc=$receipt.Expires.ToString('o');source=$Origin;staged=$staged;sha256=$receipt.Hash;destination=(Get-ReceiptInstallerDestination $game)}
   if(!$best.ContainsKey($id) -or [DateTimeOffset]::Parse($best[$id].mintedUtc) -lt $receipt.Minted){$best[$id]=$row}
  }catch{$issues.Add([pscustomobject]@{source=$Origin;message=$_.Exception.Message})}
 }
 $script:InstallerFound=0;$script:InstallerDuplicates=0
 if(Test-Path -LiteralPath $source -PathType Container){
  $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($source)
  while($pending.Count){
   if(Test-Path -LiteralPath $CancelPath){$cancelled=$true;break}
   $folder=$pending.Pop()
   try{$null=Assert-ReceiptInstallerPath $folder;$children=@(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)}catch{$issues.Add([pscustomobject]@{source=$folder;message=$_.Exception.Message});continue}
   foreach($item in $children){
    if(Test-Path -LiteralPath $CancelPath){$cancelled=$true;break}
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
    if($item.PSIsContainer){$pending.Push($item.FullName)}elseif($item.Name -ieq 'pop.bin'){
     try{if($item.Length -gt 1048576){throw 'Receipt exceeds the 1 MB limit.'};Inspect-InstallerReceipt ([IO.File]::ReadAllBytes($item.FullName)) $item.FullName}catch{$issues.Add([pscustomobject]@{source=$item.FullName;message=$_.Exception.Message})}
    }
   }
  }
 }elseif([IO.Path]::GetExtension($source) -ieq '.zip'){
  $zip=[IO.Compression.ZipFile]::OpenRead($source)
  try{foreach($entry in $zip.Entries){
   if(Test-Path -LiteralPath $CancelPath){$cancelled=$true;break}
   if(($entry.FullName -split '[/\\]')[-1] -ine 'pop.bin'){continue}
   # Never extract entry paths: stage receipt bytes under generated names only.
   if($entry.Length -gt 1048576){$issues.Add([pscustomobject]@{source=$entry.FullName;message='Receipt exceeds the 1 MB limit.'});continue}
   $input=$entry.Open();$memory=New-Object IO.MemoryStream
   try{$buffer=New-Object byte[] 8192;while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$read -gt 1048576){throw 'Receipt exceeds the 1 MB limit.'};$memory.Write($buffer,0,$read)};Inspect-InstallerReceipt $memory.ToArray() ($source+' :: '+$entry.FullName)}catch{$issues.Add([pscustomobject]@{source=$entry.FullName;message=$_.Exception.Message})}finally{$input.Dispose();$memory.Dispose()}
  }}finally{$zip.Dispose()}
 }elseif([IO.Path]::GetExtension($source) -ieq '.7z'){
  foreach($entry in @(Get-SevenZipReceiptEntries $source)){
   if(Test-Path -LiteralPath $CancelPath){$cancelled=$true;break}
   try{
    if($entry.size -gt 1048576){throw 'Receipt exceeds the 1 MB limit.'}
    # Stream the exact entry into memory; archive paths are never extracted.
    $bytes=Invoke-ReceiptArchiveTool @('x','-so','-spd','-bd','-y','--',$source,$entry.path)
    Inspect-InstallerReceipt $bytes ($source+' :: '+$entry.path)
   }catch{$issues.Add([pscustomobject]@{source=$entry.path;message=$_.Exception.Message})}
  }
 }else{throw 'Choose a folder, ZIP, or 7z archive.'}
 $rows=@($best.Values|Sort-Object game)
 $plan=[ordered]@{entries=$rows;issues=@($issues.ToArray());found=$script:InstallerFound;duplicates=$script:InstallerDuplicates;cancelled=$cancelled}
 $path=Join-Path $Run 'install-plan-private.json';$plan|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
 [pscustomobject]@{planPath=$path;entries=$rows;issues=@($issues.ToArray());found=$plan.found;duplicates=$plan.duplicates;cancelled=$cancelled;message=('Found '+$rows.Count+' supported games; '+$issues.Count+' skipped items. Newest valid receipt per game selected.')}
}
function Install-ReceiptPlan([string]$PlanPath,$Games,[bool]$IncludeUninstalled,[string]$Run,[string]$CancelPath){
 $installerRoot=[IO.Path]::GetFullPath((Join-Path $script:DataRoot 'ReceiptInstaller')).TrimEnd('\')+'\'
 $full=[IO.Path]::GetFullPath($PlanPath)
 if(!$full.StartsWith($installerRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Install preview is outside the private installer folder.'}
 $null=Assert-ReceiptInstallerPath $full
 $plan=Get-Content -LiteralPath $full -Raw|ConvertFrom-Json
 if($plan.cancelled){throw 'Scan was cancelled. Scan again before installing.'}
 $packages=@(Get-ReceiptInstallerPackages);$results=@();$installed=0;$skipped=0;$errors=0
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$mutex=New-Object Threading.Mutex($false,('Local\GFW8LG-ReceiptInstaller-'+$sid));$held=$false
 try{
  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){throw 'Another receipt installation is running.'}
  foreach($row in $plan.entries){
   if(Test-Path -LiteralPath $CancelPath){break}
   $status='skipped';$message=''
   try{
    $game=$Games|Where-Object index -eq ([int]$row.gameId)|Select-Object -First 1;if(!$game){throw 'Game is no longer in the catalogue.'}
    if(!$IncludeUninstalled -and !@($packages|Where-Object PackageFamilyName -ieq $game.package_family_name).Count){$message='Game is not installed.';$skipped++;continue}
    if(Test-ReceiptInstallerRunning $game){$message='Close the game before installing its receipt.';$skipped++;continue}
    $staged=[IO.Path]::GetFullPath([string]$row.staged);$stageRoot=[IO.Path]::GetDirectoryName($full).TrimEnd('\')+'\receipts\'
    if(!$staged.StartsWith($stageRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Preview receipt is outside its staging folder.'}
    $null=Assert-ReceiptInstallerPath $staged
    if((Get-ResearchFileHash $staged).Hash -ine $row.sha256){throw 'Preview receipt changed. Scan again.'}
    $script:TrustedReceiptHash=$null;$receipt=Read-Receipt $staged $game
    if(!$receipt.SignatureVerified -or !$receipt.Valid){throw 'Receipt is no longer valid. Scan again with a current receipt.'}
    $target=Get-ReceiptInstallerDestination $game
    if(Test-Path -LiteralPath $target){
     try{$script:TrustedReceiptHash=$null;$existing=Read-Receipt $target $game}catch{$existing=$null}
     if($existing -and $existing.SignatureVerified -and $existing.Valid -and $existing.Minted -gt $receipt.Minted){$message='A newer receipt is already installed.';$skipped++;continue}
    }
    $parent=Split-Path $target -Parent;$null=[IO.Directory]::CreateDirectory($parent);$null=Assert-ReceiptInstallerPath $target
    $temporary=Join-Path $parent ('pop-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
     [IO.File]::WriteAllBytes($temporary,(ConvertTo-GameReceiptBytes $receipt.Bytes))
     $script:TrustedReceiptHash=$null;$check=Read-Receipt $temporary $game
     if(!$check.SignatureVerified -or !$check.Valid){throw 'Receipt verification failed before replacement.'}
     if(Test-ReceiptInstallerRunning $game){throw 'The game started while installing. Close it and try again.'}
     if(Test-Path -LiteralPath $target){[IO.File]::Replace($temporary,$target,[NullString]::Value)}else{[IO.File]::Move($temporary,$target)}
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    $status='installed';$message=(Get-GuiReceiptType $receipt)+' receipt installed.';$installed++
   }catch{$status='error';$message=$_.Exception.Message;$errors++}
   finally{$results+=,[pscustomobject]@{game=$row.game;gameId=$row.gameId;status=$status;message=$message}}
  }
 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
 $summary=[pscustomobject]@{installed=$installed;skipped=$skipped;errors=$errors;cancelled=[bool](Test-Path -LiteralPath $CancelPath);entries=$results;message=($installed.ToString()+' installed; '+$skipped+' skipped; '+$errors+' errors. Existing receipts were replaced.')}
 $summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $Run 'install-summary-private.json') -Encoding UTF8
 return $summary
}

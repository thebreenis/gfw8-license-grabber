function Get-GuiReceiptType($Receipt){
 $type=[string]$Receipt.LicenseType
 if(!$type){$type='Full'} # Older internal DTOs represented Full receipts only.
 if($type -notin @('Full','Trial')){throw 'Unsupported receipt license type.'}
 return $type
}
function Get-GuiReceiptFolderName($Receipt){
 $Receipt.Minted.ToLocalTime().ToString('yyyy-MM-dd HH-mm-ss')+' - '+(Get-GuiReceiptType $Receipt)
}
function Get-GuiAvailableFolder([string]$Parent,[string]$Name){
 $prefix=[IO.Path]::GetFullPath($Parent).TrimEnd('\')+'\'
 for($n=1;;$n++){
  $leaf=if($n -eq 1){$Name}else{$Name+' ('+$n+')'}
  $candidate=[IO.Path]::GetFullPath((Join-Path $Parent $leaf))
  if(!$candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Output folder left its parent.'}
  if(!(Test-Path -LiteralPath $candidate)){return $candidate}
 }
}
function Complete-GuiReceiptFolder([string]$Run,$Receipt){
 $mutex=New-Object Threading.Mutex($false,('Local\GFW8LG-OutputFolder-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value));$held=$false
 try{
  try{$held=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
  if(!$held){throw 'Another receipt is being saved. Try again shortly.'}
 $source=[IO.Path]::GetFullPath($Run).TrimEnd('\');$parent=[IO.Path]::GetDirectoryName($source)
 $name=Get-GuiReceiptFolderName $Receipt
 if([IO.Path]::GetFileName($source) -eq $name){return $source}
 $target=Get-GuiAvailableFolder $parent $name
 # Both resolved targets are direct children of the explicitly supplied parent.
 if([IO.Path]::GetDirectoryName($target) -ne $parent){throw 'Receipt rename left its original parent.'}
 [IO.Directory]::Move($source,$target);$Receipt.Path=Join-Path $target 'pop.bin'
 return $target
 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function New-GuiOutputFolder([string]$Parent,[string]$Name){
 $mutex=New-Object Threading.Mutex($false,('Local\GFW8LG-OutputFolder-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value));$held=$false
 try{
  try{$held=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
  if(!$held){throw 'Another receipt is being saved. Try again shortly.'}
  New-PrivateFolder (Get-GuiAvailableFolder $Parent $Name)
 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Save-GuiReceiptFolderMap($Map){
 $path=Join-Path $script:DataRoot 'receipt-folder-map-private.json';$temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllText($temp,($Map|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
 if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
}
function Resolve-GuiSavedReceiptPath([string]$Path){
 $full=[IO.Path]::GetFullPath($Path)
 if(Test-Path -LiteralPath $full){return $full}
 $mapPath=Join-Path $script:DataRoot 'receipt-folder-map-private.json'
 if(Test-Path -LiteralPath $mapPath){
  $map=Get-Content -LiteralPath $mapPath -Raw|ConvertFrom-Json
  foreach($row in @($map.folders)){
   $prefix=([string]$row.old).TrimEnd('\')+'\'
   if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){
    $resolved=[IO.Path]::GetFullPath((Join-Path ([string]$row.new) $full.Substring($prefix.Length)))
    if(!$resolved.StartsWith(([IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Receipt mapping left private storage.'}
    return $resolved
   }
  }
 }
 return $full
}
function Update-GuiReceiptJsonPaths([string]$Path,$Folders){
 $raw=[IO.File]::ReadAllText($Path);$updated=$raw
 foreach($row in @($Folders)){
  $old=ConvertTo-Json -InputObject (([string]$row.old).TrimEnd('\')+'\') -Compress
  $new=ConvertTo-Json -InputObject (([string]$row.new).TrimEnd('\')+'\') -Compress
  $updated=$updated.Replace($old.Substring(1,$old.Length-2),$new.Substring(1,$new.Length-2))
 }
 if($updated -cne $raw){
  $null=$updated|ConvertFrom-Json;$time=[IO.File]::GetLastWriteTimeUtc($Path)
  [IO.File]::WriteAllText($Path,$updated,(New-Object Text.UTF8Encoding($false)));[IO.File]::SetLastWriteTimeUtc($Path,$time)
 }
}
function Move-LegacyGuiReceiptFolders {
 $mapPath=Join-Path $script:DataRoot 'receipt-folder-map-private.json'
 $mutex=New-Object Threading.Mutex($false,('Local\GFW8LG-ReceiptFolderMigration-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value));$held=$false
 try{
  try{$held=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
  if(!$held){throw 'Receipt storage is being updated. Try again shortly.'}
  $map=[ordered]@{schema=1;complete=$false;folders=@();skipped=0}
  if(Test-Path -LiteralPath $mapPath){$saved=Get-Content -LiteralPath $mapPath -Raw|ConvertFrom-Json;if($saved.complete){return};$map.folders=@($saved.folders)}
  $games=@((Get-Content (Join-Path $script:Root 'games.json') -Raw|ConvertFrom-Json).games)
  foreach($game in $games){
   $receipts=[IO.Path]::GetFullPath((Join-Path $script:DataRoot ('Games\'+(Get-GuiFamilyName $game)+'\Receipts')))
   if(!(Test-Path -LiteralPath $receipts)){continue}
   foreach($folder in @(Get-ChildItem -LiteralPath $receipts -Directory)){
    if($folder.Name -notmatch '^\d{8}-\d{6}-\d{3}-[0-9a-fA-F]{8}$'){continue}
    if($folder.Attributes -band [IO.FileAttributes]::ReparsePoint){$map.skipped++;continue}
    $pop=Join-Path $folder.FullName 'pop.bin';if(!(Test-Path -LiteralPath $pop)){continue}
    try{
     $script:TrustedReceiptHash=$null;$receipt=Read-Receipt $pop $game
     $target=Get-GuiAvailableFolder $receipts (Get-GuiReceiptFolderName $receipt)
     if([IO.Path]::GetDirectoryName($target) -ne $receipts){throw 'Invalid receipt migration target.'}
     $row=[pscustomobject]@{old=$folder.FullName;new=$target;licenseType=$receipt.LicenseType}
     $map.folders+=,$row;Save-GuiReceiptFolderMap $map
     [IO.Directory]::Move($folder.FullName,$target);$receipt.Path=Join-Path $target 'pop.bin'
     $proofPath=Join-Path $target 'receipt-proof-private.json'
     if(Test-Path -LiteralPath $proofPath){
      Update-GuiReceiptJsonPaths $proofPath @($row);$time=[IO.File]::GetLastWriteTimeUtc($proofPath)
      $proof=Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json
      $proof|Add-Member -NotePropertyName licenseType -NotePropertyValue $receipt.LicenseType -Force
      $proof|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $proofPath -Encoding UTF8
      [IO.File]::SetLastWriteTimeUtc($proofPath,$time)
     }else{
      # A previously rejected Trial response is a verified local import, not a
      # newly proved account entitlement for advertising to paired computers.
      $null=Save-ReceiptProof $game $receipt 'loaded' $target
     }
    }catch{$map.skipped++}
   }
  }
  foreach($root in @((Join-Path $script:DataRoot 'Games'),(Join-Path $script:DataRoot 'Batches'))){
   if(Test-Path -LiteralPath $root){foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse)){
    if($file.Name -in @('receipt-proof-private.json','bulk-summary-private.json')){Update-GuiReceiptJsonPaths $file.FullName $map.folders}
   }}
  }
  $map.complete=$true;Save-GuiReceiptFolderMap $map
 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

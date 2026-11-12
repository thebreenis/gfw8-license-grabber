function Quote-ReceiptArchiveArgument([string]$Value){
 $text=New-Object Text.StringBuilder;$null=$text.Append('"');$slashes=0
 foreach($ch in $Value.ToCharArray()){
  if($ch -eq '\'){$slashes++;continue}
  if($ch -eq '"'){$null=$text.Append(('\'*($slashes*2+1)))}else{$null=$text.Append(('\'*$slashes))}
  $null=$text.Append($ch);$slashes=0
 }
 $null=$text.Append(('\'*($slashes*2)));$null=$text.Append('"');return $text.ToString()
}
function Invoke-ReceiptArchiveTool([string[]]$Arguments,[int]$MaximumBytes=1048576){
 $folder=Join-Path $script:Runtime 'archive-tools'
 $pins=@{'7za.exe'='DD3757F31C97E33776F2590317D4FB12F2DA075DB3DBB1E3F94D0F2A01D84FFA'}
 foreach($name in $pins.Keys){if((Get-ResearchFileHash (Join-Path $folder $name)).Hash -ine $pins[$name]){throw 'Bundled archive reader verification failed.'}}
 $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=Join-Path $folder '7za.exe';$start.Arguments=($Arguments|ForEach-Object {Quote-ReceiptArchiveArgument $_}) -join ' ';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
 $process=New-Object Diagnostics.Process;$process.StartInfo=$start;$memory=New-Object IO.MemoryStream
 try{
  $null=$process.Start();$process.StandardInput.Close();$errors=$process.StandardError.ReadToEndAsync();$buffer=New-Object byte[] 8192
  while(($read=$process.StandardOutput.BaseStream.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$read -gt $MaximumBytes){$process.Kill();throw 'Archive entry or listing exceeds the supported size limit.'};$memory.Write($buffer,0,$read)}
  $process.WaitForExit();$null=$errors.GetAwaiter().GetResult()
  if($process.ExitCode -ne 0){throw 'The 7z archive could not be read. It may be damaged or password-protected.'}
  return ,$memory.ToArray()
 }finally{$memory.Dispose();$process.Dispose()}
}
function Get-SevenZipReceiptEntries([string]$Path){
 $bytes=Invoke-ReceiptArchiveTool @('l','-slt','-sccUTF-8','-bd','--',$Path) 16777216
 $listing=[Text.Encoding]::UTF8.GetString($bytes);$sections=$listing -split '----------\r?\n',2
 if($sections.Count -ne 2){throw 'The archive reader returned an invalid listing.'}
 foreach($block in ($sections[1] -split '\r?\n\r?\n')){
  $row=@{};foreach($line in ($block -split '\r?\n')){if($line -match '^([^=]+) = (.*)$'){$row[$matches[1].Trim()]=$matches[2]}}
  if(!$row.ContainsKey('Path') -or ($row.Path -split '[/\\]')[-1] -ine 'pop.bin'){continue}
  if($row.Keys|Where-Object {$_ -like '*Link*'}){continue}
  if($row.Folder -eq '+' -or $row.Attributes -match '(^|\s)l'){continue}
  [pscustomobject]@{path=[string]$row.Path;size=[long]$row.Size}
 }
}

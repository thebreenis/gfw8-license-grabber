param([switch]$LayoutTest,[string]$LayoutReceiptPath)
$ErrorActionPreference='Stop'
$appRoot=$PSScriptRoot
if($PSVersionTable.PSEdition -ne 'Desktop' -or ![Environment]::Is64BitProcess){throw 'Use GFW8 License Grabber.exe with Windows PowerShell 5.1 x64.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. "$appRoot\backend\Core.ps1"
. "$appRoot\GuiBackend.ps1"
. "$appRoot\InstalledGames.ps1"
. "$appRoot\LegacyPackageRecovery.ps1"
Initialize-GuiStorage
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText("$appRoot\MainWindow.xaml"))
Add-Type -Path (Join-Path $appRoot 'WindowBounds.cs') -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Media.Visual].Assembly.Location,[Windows.DependencyObject].Assembly.Location,[Windows.Markup.IQueryAmbient].Assembly.Location)
[Gfw8WindowBounds]::Install($window)
$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $appRoot 'App.ico'))
$script:ui=@{}
foreach($name in @('TitleDrag','Minimize','Maximize','Close','GamePicker','AccountEmail','AccountGamertag','ReceiptStatus','ReceiptDetail','ReceiptMinted','ReceiptExpires','ReceiptButton','LoadButton','ReceiptBusy','ReceiptProgress','ReceiptProgressText','ReceiptEta','TokenStatus','TokenDetail','TokenIssued','TokenExpires','TokenButton','TokenBusy','TokenProgress','TokenProgressText','TokenEta','CopyToken','PresenceStatus','PresenceDetail','PresenceButton','PresenceBusy','PresenceProgress','PresenceProgressText','PresenceEta','BulkButton','BulkBusy','BulkProgress','BulkProgressText','BulkSummary','CancelBulk','Activity','CopyLog','SaveLog','GitHub','OpenFiles')){$script:ui[$name]=$window.FindName($name)}
foreach($name in @('AppScale','MainContent','RecoveryOverlay','RecoveryTitle','RecoveryMessage','RecoveryDetail','RecoveryOpen','RecoveryCancel','RecoveryWaiting','RecoveryProgress','RecoveryProgressLabel')){$script:ui[$name]=$window.FindName($name)}
. "$appRoot\LegacyRecoveryUi.ps1"
$script:games=@((Get-Content "$appRoot\backend\games.json" -Raw|ConvertFrom-Json).games)
$script:state=@{receipt=$null;token=$null;job=$null;email=$null;gamertag=$null;applyingSelection=$false;closeWhenFinished=$false;logLines=(New-Object Collections.Generic.List[string]);stageStart=[DateTime]::UtcNow;stageSeconds=8;stageText='';testMode=[bool]$LayoutTest;recovery=$null;installed=$false;availabilityKnown=$false;pendingInstalledScan=$null;scanDue=[DateTime]::UtcNow}
function Add-Activity([string]$Text,[string]$Level='info'){
 if([string]::IsNullOrWhiteSpace($Text)){return}
 $safe=Protect-LogText $Text
 $line=[DateTime]::Now.ToString('HH:mm:ss')+'  '+$(if($Level -eq 'error'){'ERROR  '}elseif($Level -eq 'warning'){'NOTE   '}else{''})+$safe
 $state.logLines.Add($line)
 if($state.logLines.Count -gt 1800){$state.logLines.RemoveAt(0)}
 $ui.Activity.Text=($state.logLines -join "`r`n")
 $ui.Activity.ScrollToEnd()
}
function Short-Time([string]$Value){if(!$Value){return '—'};([DateTimeOffset]::Parse($Value)).ToLocalTime().ToString('dd MMM yyyy, HH:mm:ss zzz')}
function Add-OperationError([string]$Text){
 $safe=Protect-LogText $Text
 if($state.job){
  if(!$state.job.reportedErrors){$state.job|Add-Member -NotePropertyName reportedErrors -NotePropertyValue (New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)) -Force}
  if(!$state.job.reportedErrors.Add($safe)){return}
 }
 Add-Activity $safe 'error'
}
function Is-Current([object]$Item){return ($null -ne $Item -and [DateTimeOffset]::Parse([string]$Item.expiresUtc) -gt [DateTimeOffset]::UtcNow)}
function Set-Visible($Control,[bool]$Visible){$Control.Visibility=if($Visible){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
function Update-Controls {
 $busy=($null -ne $state.job -or $state.pendingRestore);$game=$ui.GamePicker.SelectedItem
 $receiptGood=Is-Current $state.receipt;$tokenGood=Is-Current $state.token
 $ui.GamePicker.IsEnabled=(!$busy -or ($state.job -and $state.job.action -eq 'availability'))
 $ui.ReceiptButton.IsEnabled=(!$busy -and $null -ne $game)
 $ui.LoadButton.IsEnabled=!$busy
 $ui.TokenButton.IsEnabled=(!$busy -and $receiptGood -and $null -ne $game -and $game.tokenAttemptAvailable -and $state.availabilityKnown -and !$state.installed)
 $ui.TokenButton.ToolTip=if($state.installed){'The selected game''s installation interferes with GFW8LG''s ability to grab the token. Please uninstall the selected game and try again.'}else{$null}
 $ui.PresenceButton.IsEnabled=(!$busy -and $tokenGood -and $state.availabilityKnown -and !$state.installed)
 $ui.BulkButton.IsEnabled=!$busy
 Set-Visible $ui.CopyToken ($tokenGood -and (!$busy -or $state.job.action -ne 'token'))
 if($state.receipt -and !$receiptGood){$ui.ReceiptStatus.Text='Receipt expired';$ui.ReceiptDetail.Text='Get a new pop.bin to mint more tokens.'}
 if($state.token -and !$tokenGood){$ui.TokenStatus.Text='Token expired';$ui.TokenDetail.Text='Use a valid receipt to request another.'}
 foreach($pair in @(@('Receipt','receipt'),@('Token','token'),@('Presence','presence'),@('Bulk','bulk'))){
  $prefix=$pair[0];$action=$pair[1];$active=$busy -and ($state.job.action -eq $action -or ($action -eq 'receipt' -and $state.job.action -in @('load')))
  Set-Visible $ui[($prefix+'Busy')] $active
  Set-Visible $ui[($prefix+'Button')] (!$active)
 }
 Set-Visible $ui.CancelBulk ($busy -and $state.job.action -eq 'bulk')
 Set-Visible $ui.ReceiptEta ($busy -and $state.job.action -in @('receipt','load'))
 Set-Visible $ui.TokenEta ($busy -and $state.job.action -eq 'token')
 if(!$busy -or $state.job.action -ne 'presence'){$ui.PresenceEta.Text=''}
}
function Set-InstallationStatus {
 if($state.installed){
  $ui.TokenStatus.Text='Game installed'
  $ui.TokenDetail.Text='The selected game''s installation interferes with GFW8LG''s ability to grab the token. Please uninstall the selected game and try again.'
  $ui.PresenceStatus.Text='Game installed'
  $ui.PresenceDetail.Text='Fresh pop.bin acquisition is available.'
 }elseif(!$state.token){
  $ui.TokenStatus.Text='No token yet'
  $ui.TokenDetail.Text=if(!$ui.GamePicker.SelectedItem.tokenAttemptAvailable){'Token metadata is not available for this title.'}elseif(Is-Current $state.receipt){'Use this receipt to mint a token.'}else{'A valid receipt is required.'}
  $ui.PresenceStatus.Text='Ready after token';$ui.PresenceDetail.Text='Verify presence and submit Last Played.'
 }
}
function Reset-Selection {
 $state.receipt=$null;$state.token=$null;$state.installed=$false;$state.availabilityKnown=$false
 $state.pendingInstalledScan=[int]$ui.GamePicker.SelectedItem.index;$state.scanDue=[DateTime]::UtcNow.AddMilliseconds(350)
 $ui.ReceiptStatus.Text='No receipt yet';$ui.ReceiptDetail.Text='Get or load a valid pop.bin.'
 $ui.ReceiptMinted.Text='—';$ui.ReceiptExpires.Text='—'
 $ui.TokenStatus.Text='No token yet';$ui.TokenDetail.Text=if($ui.GamePicker.SelectedItem.tokenAttemptAvailable){'Checking whether the game is installed…'}else{'Token metadata is not available for this title.'}
 $ui.TokenIssued.Text='—';$ui.TokenExpires.Text='—'
 $ui.PresenceStatus.Text='Ready after token';$ui.PresenceDetail.Text='Verify presence and submit Last Played.'
 Update-Controls
}
function Start-Operation([string]$Action,$Extra){
 if($state.job){return}
 if($Action -ne 'account'){$state.pendingInstalledScan=$null}
 if($Action -eq 'token'){$state.token=$null;$state.gamertag=$null;$ui.AccountGamertag.Text='Xbox profile: checking after token…';$ui.TokenIssued.Text='—';$ui.TokenExpires.Text='—';$ui.PresenceStatus.Text='Ready after token'}
 $logs=Ensure-GuiFolder (Join-Path $script:DataRoot 'Logs')
 $jobs=Ensure-GuiFolder (Join-Path $logs 'Jobs')
 $folder=New-PrivateFolder (Join-Path $jobs ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+$Action+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)))
 $request=[ordered]@{action=$Action;gameId=$(if($ui.GamePicker.SelectedItem){[int]$ui.GamePicker.SelectedItem.index}else{0});storeAccount=$state.email}
 if($Extra){foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}}
 $requestPath=Join-Path $folder 'request-private.json'
 $request|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $requestPath -Encoding UTF8
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=Join-Path $PSHOME 'powershell.exe'
 $start.Arguments='-NoProfile -MTA -ExecutionPolicy Bypass -File "'+(Join-Path $appRoot 'Worker.ps1')+'" -RequestPath "'+$requestPath+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden;$start.WorkingDirectory=$appRoot
 $process=[Diagnostics.Process]::Start($start)
 $state.job=[pscustomobject]@{action=$Action;gameId=$request.gameId;folder=$folder;process=$process;linesRead=0;started=[DateTime]::UtcNow}
 $state.stageStart=[DateTime]::UtcNow;$state.stageSeconds=if($Action -eq 'presence'){20}else{8};$state.stageText=switch($Action){'load'{'Checking receipt…'}'packageRecovery'{'Restoring original package…'}'receipt'{'Getting pop.bin…'}'token'{'Getting Xbox token…'}'presence'{'Checking presence…'}'bulk'{'Starting…'}default{'Reading account…'}}
 $state.overallProgress=0.0;$state.stageFloor=0.0;$state.stageCeiling=if($Action -eq 'token'){80.0}elseif($Action -eq 'presence'){35.0}else{97.0}
 if($Action -eq 'bulk'){$ui.BulkSummary.Text='Starting entitlement checks…';$ui.CancelBulk.IsEnabled=$true;$ui.BulkProgress.Value=0}
 Add-Activity ($(switch($Action){'account'{'Reading Windows account.'}'receipt'{'Requesting a receipt for '+$ui.GamePicker.SelectedItem.name+'.'}'packageRecovery'{'Retrying original package restoration.'}'load'{'Loading the selected receipt.'}'token'{'Requesting a token for '+$ui.GamePicker.SelectedItem.name+'.'}'presence'{'Starting the selected token Presence test.'}'bulk'{'Checking all 108 receipt entitlements.'}}))
 Update-Controls
}
function Apply-Event($Event){
 switch($Event.kind){
  'transaction' {
   $state.overallProgress=[Math]::Max($state.overallProgress,[double]$Event.percent);$state.stageStart=[DateTime]::UtcNow;$state.stageFloor=$state.overallProgress
   $state.stageCeiling=if($Event.percent -lt 18){17.0}elseif($Event.percent -lt 24){23.0}elseif($Event.percent -lt 36){35.0}elseif($Event.percent -lt 52){51.0}elseif($Event.percent -lt 65){64.0}elseif($Event.percent -lt 82){81.0}elseif($Event.percent -lt 92){91.0}elseif($Event.percent -lt 96){95.0}else{99.0}
   if($state.stageCeiling -lt $state.overallProgress){$state.stageCeiling=$state.overallProgress}
   $state.stageText=[string]$Event.text;$state.stageSeconds=12
   $ui.RecoveryProgress.Value=$state.overallProgress;$ui.RecoveryProgressLabel.Text=[string]$Event.text
  }
  'log' {if($Event.level -eq 'error'){Add-OperationError ([string]$Event.text)}else{Add-Activity ([string]$Event.text) ([string]$Event.level)}}
  'account' {
   if($Event.PSObject.Properties['email']){$state.email=[string]$Event.email;$ui.AccountEmail.Text=$state.email;$ui.AccountEmail.ToolTip=$state.email}
   if($Event.PSObject.Properties['gamertag'] -and $Event.gamertag){$state.gamertag=[string]$Event.gamertag;$ui.AccountGamertag.Text='Xbox profile: '+$state.gamertag}
  }
  'stage' {
   $state.stageText=[string]$Event.text;$state.stageSeconds=[double]$Event.seconds;$state.stageStart=[DateTime]::UtcNow
   $floor=0.0;$ceiling=$state.stageCeiling
   if($state.job.action -eq 'token'){
    if($Event.text -like 'Reading Xbox profile*'){$floor=90.0;$ceiling=99.0}
    elseif($Event.text -like 'Windows sign-in*'){$floor=65.0;$ceiling=85.0}
    else{$ceiling=80.0}
   }elseif($state.job.action -eq 'presence'){
    if($Event.text -like '*cleanup*'){$floor=85.0;$ceiling=99.0}
    elseif($Event.text -like '*Last Played*'){$floor=75.0;$ceiling=85.0}
    elseif($Event.text -like '*confirmation*'){$floor=35.0;$ceiling=75.0}
   }
   $state.overallProgress=[Math]::Max($state.overallProgress,$floor)
   $state.stageFloor=$state.overallProgress;$state.stageCeiling=[Math]::Max($ceiling,$state.overallProgress)
  }
  'bulk' {
   $ui.BulkProgress.IsIndeterminate=$false;$ui.BulkProgress.Value=100*[double]$Event.done/[double]$Event.total
   $ui.BulkProgressText.Text=([string]$Event.done+' / '+$Event.total+' checked')
   $estimate=if($Event.remainingSeconds -ge 60){'About '+[Math]::Ceiling($Event.remainingSeconds/60)+' min remaining'}else{'About '+$Event.remainingSeconds+' sec remaining'}
   $ui.BulkSummary.Text=($Event.saved.ToString()+' saved · '+$Event.unlicensed+' unlicensed · '+$Event.errors+' errors · '+$estimate)
  }
 }
}
function Read-WorkerEvents {
 $job=$state.job;if(!$job){return}
 $path=Join-Path $job.folder 'events.jsonl';if(!(Test-Path -LiteralPath $path)){return}
 $stream=$null;$reader=$null
 try{
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  $reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false)))
  $text=$reader.ReadToEnd();$lines=$text -split "`n";$complete=$lines.Count-1
  for($i=$job.linesRead;$i -lt $complete;$i++){
   if($lines[$i].Trim()){Apply-Event ($lines[$i]|ConvertFrom-Json)}
   $job.linesRead=$i+1
  }
 }catch{}finally{if($reader){$reader.Dispose()};if($stream){$stream.Dispose()}}
}
function Complete-Operation {
 $job=$state.job
 Read-WorkerEvents
 $path=Join-Path $job.folder 'result.json'
 try{
  if(!(Test-Path -LiteralPath $path)){throw 'The background operation exited without a result. Diagnostic files were retained.'}
  $result=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if(!$result.success){
   if($result.restoreRequired){Show-InstalledRestoreRequired $result;Add-OperationError ([string]$result.message);return}
   if($job.action -in @('receipt','load')){$ui.ReceiptStatus.Text=if($result.unlicensed){'No license on this account'}else{'Receipt not loaded'};$ui.ReceiptDetail.Text=if($state.receipt){'Previous receipt retained. See Activity.'}else{'See Activity for details.'};$ui.ReceiptDetail.ToolTip=[string]$result.message}
   if($job.action -eq 'token'){$ui.TokenStatus.Text='Token not acquired';$ui.TokenDetail.Text='See Activity for sign-in or service details.';$ui.TokenDetail.ToolTip=[string]$result.message;$ui.AccountGamertag.Text='Xbox profile: unavailable for this attempt'}
   if($job.action -eq 'presence'){$ui.PresenceStatus.Text='Presence not confirmed';$ui.PresenceDetail.Text='See Activity for service details.';$ui.PresenceDetail.ToolTip=[string]$result.message}
   if($job.action -eq 'bulk'){$ui.BulkSummary.Text=[string]$result.message}
   if($job.action -eq 'availability'){$state.availabilityKnown=$false;$ui.TokenDetail.Text='Installation check unavailable. Select the game again to retry.'}
   if($job.action -eq 'account'){$ui.AccountEmail.Text='Account unavailable';$ui.AccountGamertag.Text='Xbox profile: available after sign-in'}
   Add-OperationError ([string]$result.message)
   if($result.installedBlocked){$state.installed=$true;$state.availabilityKnown=$true;Set-InstallationStatus}
  }else{
   $data=$result.data
   if($data.restoreRequired){Show-InstalledRestoreRequired $data;return}
   switch($job.action){
    'account' {$state.pendingInstalledScan=[int]$ui.GamePicker.SelectedItem.index;$state.scanDue=[DateTime]::UtcNow}
    'packageRecovery' {$state.pendingRestore=$false;Hide-ReceiptRecovery;$state.pendingInstalledScan=[int]$ui.GamePicker.SelectedItem.index;$state.scanDue=[DateTime]::UtcNow}
    'availability' {if($job.gameId -eq [int]$ui.GamePicker.SelectedItem.index){$state.installed=[bool]$data.installed;$state.availabilityKnown=$true;Set-InstallationStatus}}
    {$_ -in @('receipt','load')} {
     $state.installed=[bool]$data.installed;$state.availabilityKnown=$true
     if($data.cancelled){Hide-ReceiptRecovery;break}
     if(!$data.receipt){break}
     $receipt=$data.receipt
     if($job.action -eq 'load'){
      $state.applyingSelection=$true
      $ui.GamePicker.SelectedItem=$games|Where-Object index -eq ([int]$receipt.gameId)
      $state.applyingSelection=$false
     }
     # A different receipt invalidates the GUI's token association, never the saved token files.
     $state.receipt=$receipt;$state.token=$null
     $ui.ReceiptStatus.Text=if($receipt.origin -eq 'loaded'){'Receipt loaded'}else{'Receipt saved'}
     $ui.ReceiptDetail.Text='pop.bin · Full license'
     $ui.ReceiptMinted.Text=Short-Time $receipt.mintedUtc;$ui.ReceiptExpires.Text=Short-Time $receipt.expiresUtc
     $ui.TokenStatus.Text='No token yet';$ui.TokenIssued.Text='—';$ui.TokenExpires.Text='—'
     $ui.TokenDetail.Text=if($state.installed){'The selected game''s installation interferes with GFW8LG''s ability to grab the token. Please uninstall the selected game and try again.'}elseif($ui.GamePicker.SelectedItem.tokenAttemptAvailable){'Use this receipt to mint a token.'}else{'Token metadata unavailable for this title.'}
     $ui.PresenceStatus.Text='Ready after token';Set-InstallationStatus
    }
    'token' {
     $state.token=$data.token;$ui.TokenStatus.Text='Token acquired'
     if(!$data.token.gamertag){$ui.AccountGamertag.Text='Xbox profile: lookup unavailable'}
     $ui.TokenDetail.Text=if($data.token.dataPreservationAlert){'App-data alert: before/after copies retained.'}else{'Saved to file · 4-hour issuance reference'}
     $ui.TokenIssued.Text=Short-Time $data.token.issuedUtc;$ui.TokenExpires.Text=Short-Time $data.token.expiresUtc
     $ui.PresenceStatus.Text='Ready to test';$ui.PresenceDetail.Text='Verify presence and submit Last Played.'
    }
    'presence' {$ui.PresenceStatus.Text=if($data.presence.cleanupRequired -and (!$data.presence.cleanupAccepted -or !$data.presence.targetAbsentAfterCleanup)){'Cleanup unconfirmed'}elseif($data.presence.presenceWriteAccepted -and $data.presence.activeReadback){'Presence successful'}elseif($data.presence.presenceWriteAccepted){'Confirmation pending'}else{'Presence test failed'};$ui.PresenceDetail.Text=if($data.presence.lastPlayedWriteAccepted){'Last Played submission accepted.'}else{'See Activity for the service results.'}}
    'bulk' {$ui.BulkSummary.Text=($data.bulk.saved.ToString()+' saved · '+$data.bulk.unlicensed+' unlicensed · '+$data.bulk.errors+' errors · '+$data.bulk.checked+' / '+$data.bulk.total+' checked'+$(if($data.bulk.cancelled){' · cancelled'}))}
   }
  }
 }catch{Add-OperationError $_.Exception.Message}
 finally{$job.process.Dispose();$state.job=$null;if(!$state.availabilityKnown -and $job.action -ne 'availability'){$state.pendingInstalledScan=[int]$ui.GamePicker.SelectedItem.index;$state.scanDue=[DateTime]::UtcNow};Update-Controls;if($state.pendingRestore){$state.closeWhenFinished=$false}elseif($state.closeWhenFinished){$window.Close()}}
}
function Update-Progress {
 if(!$state.job){return}
 $action=$state.job.action
 $prefix=switch($action){'receipt'{'Receipt'}'load'{'Receipt'}'packageRecovery'{'Receipt'}'token'{'Token'}'presence'{'Presence'}'bulk'{'Bulk'}default{$null}}
 if(!$prefix -or $action -eq 'bulk'){return}
 $elapsed=([DateTime]::UtcNow-$state.stageStart).TotalSeconds
 $bar=$ui[($prefix+'Progress')];$label=$ui[($prefix+'ProgressText')];$eta=$ui[($prefix+'Eta')]
 $label.Text=$state.stageText
 $bar.IsIndeterminate=$false
 if($state.stageSeconds -le 0){$eta.Text='Waiting for Windows, if interaction is required.'}
 else{
  $fraction=1-[Math]::Exp(-$elapsed/[Math]::Max(1,$state.stageSeconds))
  $state.overallProgress=[Math]::Max($state.overallProgress,$state.stageFloor+($state.stageCeiling-$state.stageFloor)*$fraction)
  $left=[Math]::Ceiling($state.stageSeconds-$elapsed+$(if($action -eq 'token' -and $state.stageCeiling -lt 90){3}elseif($action -eq 'presence' -and $state.stageCeiling -lt 85){20}else{0}))
  $eta.Text=if($left -gt 0){'About '+$left+' seconds remaining'}else{'Taking longer than usual…'}
 }
 $bar.Value=$state.overallProgress
 if($action -in @('packageRecovery')){$ui.RecoveryProgress.Value=$state.overallProgress;$ui.RecoveryProgressLabel.Text=$state.stageText}
}
$ui.GamePicker.ItemsSource=$games
Add-Type -Path (Join-Path $appRoot 'GamePickerBehavior.cs') -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Media.Visual].Assembly.Location,[Windows.DependencyObject].Assembly.Location,[Windows.Markup.IQueryAmbient].Assembly.Location)
[Gfw8GamePickerBehavior]::Install($ui.GamePicker)
$ui.GamePicker.SelectedIndex=0
$script:typeBuffer='';$script:lastType=[DateTime]::MinValue
$ui.GamePicker.IsTextSearchEnabled=$false
$ui.GamePicker.add_PreviewMouseDown({$null=$ui.GamePicker.Focus();$script:typeBuffer='';$script:lastType=[DateTime]::MinValue})
$ui.GamePicker.add_PreviewTextInput({param($sender,$eventArgs)
 if(([DateTime]::UtcNow-$script:lastType).TotalSeconds -gt 3){$script:typeBuffer=''}
 $text=[string]$eventArgs.Text
 $cycle=($text.Length -eq 1 -and $script:typeBuffer -ieq $text)
 $candidate=if($cycle){$text}else{$script:typeBuffer+$text}
 $match=Find-GuiGameByText $games $candidate ([int]$ui.GamePicker.SelectedItem.index) -Cycle:$cycle
 if(!$match){$candidate=$text;$match=Find-GuiGameByText $games $candidate}
 if($match){$ui.GamePicker.SelectedItem=$match;$script:typeBuffer=$candidate}
 $script:lastType=[DateTime]::UtcNow;$eventArgs.Handled=$true
})
$ui.GamePicker.add_PreviewKeyDown({param($sender,$eventArgs)
 if($eventArgs.Key -in @([Windows.Input.Key]::Escape,[Windows.Input.Key]::Up,[Windows.Input.Key]::Down,[Windows.Input.Key]::Home,[Windows.Input.Key]::End)){$script:typeBuffer=''}
})
$ui.GamePicker.add_SelectionChanged({if(!$state.applyingSelection){Reset-Selection}})
Reset-Selection
$ui.ReceiptButton.add_Click({try{Start-Operation 'receipt' $null}catch{Add-Activity $_.Exception.Message 'error'}})
$ui.RecoveryOpen.add_Click({Retry-LegacyPackageRecovery})
$ui.RecoveryCancel.add_Click({Close-LegacyRecovery})
$ui.RecoveryOverlay.add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Escape){Close-LegacyRecovery;$eventArgs.Handled=$true}})
$ui.LoadButton.add_Click({
 $dialog=New-Object Microsoft.Win32.OpenFileDialog
 $dialog.Title='Load existing receipt';$dialog.Filter='Xbox Store receipt (pop.bin)|pop.bin|Binary receipt (*.bin)|*.bin|All files (*.*)|*.*';$dialog.CheckFileExists=$true
 if($dialog.ShowDialog($window)){try{Start-Operation 'load' @{path=$dialog.FileName}}catch{Add-Activity $_.Exception.Message 'error'}}
})
$ui.TokenButton.add_Click({try{Start-Operation 'token' @{proofPath=$state.receipt.proofPath}}catch{Add-Activity $_.Exception.Message 'error'}})
$ui.PresenceButton.add_Click({try{Start-Operation 'presence' @{token=$state.token}}catch{Add-Activity $_.Exception.Message 'error'}})
$ui.BulkButton.add_Click({try{Start-Operation 'bulk' $null}catch{Add-Activity $_.Exception.Message 'error'}})
$ui.CancelBulk.add_Click({if($state.job -and $state.job.action -eq 'bulk'){[IO.File]::WriteAllText((Join-Path $state.job.folder 'cancel.flag'),'cancel');$ui.CancelBulk.IsEnabled=$false;$ui.BulkSummary.Text='Cancelling after the current request finishes…';Add-Activity 'Bulk cancellation requested; completed files will be retained.'}})
$ui.CopyToken.add_Click({
 try{if(!(Is-Current $state.token)){throw 'The token has expired.'};[Windows.Clipboard]::SetText([IO.File]::ReadAllText((Join-Path $state.token.exportPath 'issued-token.xml')).Trim());Add-Activity 'Token copied to clipboard.'}
 catch{Add-Activity ('Could not copy token: '+$_.Exception.Message) 'error'}
})
$ui.CopyLog.add_Click({try{[Windows.Clipboard]::SetText(($state.logLines -join "`r`n"));Add-Activity 'Activity log copied to clipboard.'}catch{Add-Activity 'Clipboard is busy. Try again.' 'error'}})
$ui.SaveLog.add_Click({
 $dialog=New-Object Microsoft.Win32.SaveFileDialog
 $dialog.Title='Save activity log';$dialog.Filter='Text log (*.txt)|*.txt';$dialog.FileName='GFW8-License-Grabber-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.txt';$dialog.OverwritePrompt=$true
 if($dialog.ShowDialog($window)){try{[IO.File]::WriteAllLines($dialog.FileName,$state.logLines,(New-Object Text.UTF8Encoding($false)));Add-Activity 'Activity log saved.'}catch{Add-Activity 'Could not save activity log.' 'error'}}
})
$ui.OpenFiles.add_Click({[Diagnostics.Process]::Start('explorer.exe','"'+$script:DataRoot+'"')|Out-Null})
$ui.GitHub.add_Click({[Diagnostics.Process]::Start('https://github.com/thebreenis')|Out-Null})
$ui.Minimize.add_Click({$window.WindowState='Minimized'})
$ui.Maximize.add_Click({$window.WindowState=if($window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}})
$ui.Close.add_Click({$window.Close()})
$ui.TitleDrag.add_MouseLeftButtonDown({param($sender,$eventArgs) if($eventArgs.ClickCount -eq 2){$window.WindowState=if($window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}}else{$window.DragMove()}})
$window.add_Closing({param($sender,$eventArgs)
 if($state.job){$eventArgs.Cancel=$true;$state.closeWhenFinished=$true
  if($state.job.action -in @('bulk')){[IO.File]::WriteAllText((Join-Path $state.job.folder 'cancel.flag'),'cancel')}
  Add-Activity 'Finishing the current operation before closing. Complete or cancel any Windows sign-in prompt.'
 }
})
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(250)
$timer.add_Tick({
 try{
  if($state.job){Read-WorkerEvents;Update-Progress;if($state.job.process.HasExited){Complete-Operation}}
  if(!$state.job -and !$state.pendingRestore -and $null -ne $state.pendingInstalledScan -and [DateTime]::UtcNow -ge $state.scanDue){Start-Operation 'availability' $null}
  Update-Controls
 }catch{Add-Activity ('Display update: '+$_.Exception.Message) 'error'}
})
$timer.Start()
$window.add_ContentRendered({
 if($state.testMode){
  $ui.AccountEmail.Text='player@example.com';$ui.AccountGamertag.Text='Xbox profile: PlayerOne'
  Add-Activity 'Layout test — no account or network request made.'
  if($LayoutReceiptPath){Start-Operation 'load' @{path=$LayoutReceiptPath}}
 }else{Start-Operation 'account' $null}
})
try{$null=$window.ShowDialog()}finally{$timer.Stop()}



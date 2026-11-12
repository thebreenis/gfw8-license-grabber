$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
. "$repo\build\staging\backend\Core.ps1"
. "$repo\build\staging\backend\runtime\xbox-auth\NativeProcessCapture.ps1"
$report=[pscustomobject]@{stage='xbox-response';tokenIssued=$false;nativeXboxJwt=$false;helperStopped=$true;privateSessionRemoved=$true;helperRegistrationRemoved=$true;xErr='0x8015DA87';faultText=@('s:Sender','The creator of this fault did not specify a Reason.')}
$life=[pscustomobject]@{registrationRemoved=$true}
$message=Get-TokenFailureMessage $report $life
if($message -ne 'Xbox rejected the token request (0x8015DA87). The server did not provide a specific reason.'){throw 'Server rejection message lost error code/reason status'}
if((Get-TokenOutcome 1 $report $life $false) -ne 'failed'){throw 'SOAP rejection was considered successful'}
$life.registrationRemoved=$false
if((Get-TokenFailureMessage $report $life) -notlike '*cleanup is not confirmed*'){throw 'Actual cleanup problem was hidden'}
$life.registrationRemoved=$true;$life|Add-Member -NotePropertyName cleanupFailureType -NotePropertyValue 'SyntheticRemovalFailure'
if((Get-TokenFailureMessage $report $life) -notlike '*cleanup is not confirmed*'){throw 'App-data preservation problem was hidden'}
$life.cleanupFailureType=$null;$life|Add-Member -NotePropertyName dataPreservationFailureType -NotePropertyValue 'SyntheticDataChange'
if((Get-TokenFailureMessage $report $life) -notlike 'Xbox rejected*'){throw 'Data changes were conflated with helper cleanup'}
$script:cleanupLines=New-Object 'Collections.Generic.List[string]'
function Write-Host {param([Parameter(Position=0)]$Object,$ForegroundColor)$script:cleanupLines.Add([string]$Object)}
Write-TokenCleanupStatus $report $life
if($script:cleanupLines[0] -notlike 'Helper cleanup: complete*'){throw 'Successful cleanup activity missing'}
$life.registrationRemoved=$false;Write-TokenCleanupStatus $report $life
if($script:cleanupLines[1] -notlike '*registration: removal unconfirmed*'){throw 'Unconfirmed cleanup component missing'}
$root=New-PrivateFolder (Join-Path $repo ('build\token-errors-'+[guid]::NewGuid().ToString('N')))
$child=Join-Path $root 'error-child.ps1';[IO.File]::WriteAllText($child,'[Console]::Out.WriteLine(''{"tokenIssued":false}'');[Console]::Error.WriteLine(''Xbox rejected the token request (0x8015DA87).'');exit 1')
$log=Join-Path $root 'capture.log';$capture=Invoke-CapturedAuthDriver (Join-Path $PSHOME 'powershell.exe') @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child) $log
$text=Get-Content $log -Raw
if($capture.ExitCode -ne 1 -or $text -notlike '*0x8015DA87*' -or $text -match 'NativeCommandError|CategoryInfo|FullyQualifiedErrorId'){throw 'Child capture added PowerShell error formatting'}
. "$repo\build\staging\GuiBackend.ps1"
$script:EventWriter=New-Object IO.StringWriter;$life.registrationRemoved=$true
Write-TokenCleanupStatus $report $life
$event=$script:EventWriter.ToString()|ConvertFrom-Json
if($event.kind -ne 'log' -or $event.level -ne 'info' -or $event.text -notlike 'Helper cleanup: complete*'){throw 'Cleanup status did not reach the GUI Activity event stream'}
$script:EventWriter.Dispose();$script:EventWriter=$null
Microsoft.PowerShell.Utility\Write-Output 'PASS token rejection formatting, no false success, cleanup failure priority and raw child capture without NativeCommandError noise. Synthetic data only.'

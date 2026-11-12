# Shown only if a previous v1.3 package transaction still needs restoration.
function Hide-ReceiptRecovery {
 $ui.RecoveryOverlay.Visibility='Collapsed';$ui.MainContent.IsEnabled=$true;$state.recovery=$null
}
function Retry-LegacyPackageRecovery {
 if(!$state.recovery -or $state.job){return}
 Start-Operation 'packageRecovery' @{recoveryPath=$state.recovery.recoveryPath}
 $ui.RecoveryOpen.Visibility='Collapsed';$ui.RecoveryWaiting.Visibility='Visible'
 $ui.RecoveryCancel.IsEnabled=$false;$ui.RecoveryCancel.Content='Restoring…'
}
function Close-LegacyRecovery {if(!$state.job){$window.Close()}}
function Show-InstalledRestoreRequired($Data){
 $state.pendingRestore=$true;$state.recovery=@{recoveryPath=$Data.recoveryPath}
 $ui.RecoveryTitle.Text='Previous operation needs recovery'
 $ui.RecoveryMessage.Text='An unfinished operation from an earlier version still needs its original package restored. See Activity for the Windows deployment error, then retry.'
 $ui.RecoveryDetail.Text='Retained recovery files remain available. New work is blocked until restoration completes.'
 $ui.RecoveryOpen.Content='Retry restoration';$ui.RecoveryOpen.Visibility='Visible'
 $ui.RecoveryCancel.Content='Close app';$ui.RecoveryCancel.IsEnabled=$true
 $ui.RecoveryWaiting.Visibility='Collapsed';$ui.RecoveryOverlay.Visibility='Visible';$ui.MainContent.IsEnabled=$false
}

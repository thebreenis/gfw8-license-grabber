$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$bundle=Join-Path (Split-Path $PSScriptRoot -Parent) 'build\staging'
Add-Type -Path "$bundle\GamePickerBehavior.cs" -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Media.Visual].Assembly.Location,[Windows.DependencyObject].Assembly.Location,[Windows.Markup.IQueryAmbient].Assembly.Location)
$window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText("$bundle\MainWindow.xaml"))
$picker=$window.FindName('GamePicker')
$picker.ItemsSource=(Get-Content "$bundle\backend\games.json" -Raw|ConvertFrom-Json).games
$picker.SelectedIndex=0
[Gfw8GamePickerBehavior]::Install($picker)
$checks=0
function Assert($Ok,$Message){if(!$Ok){throw $Message};$script:checks++}
function Pump {$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)}
try{
 $window.Show();$null=$window.Activate();$picker.Focus()|Out-Null
 $picker.IsDropDownOpen=$true;Pump
 $scroll=$picker.Template.FindName('GamePickerScroll',$picker)
 Assert ($null -ne $scroll -and !$scroll.CanContentScroll) 'Popup uses pixel scrolling'
 $scroll.ScrollToVerticalOffset(0);Pump
 $row=$picker.ItemContainerGenerator.ContainerFromIndex(0)
 $wheel=New-Object Windows.Input.MouseWheelEventArgs([Windows.Input.Mouse]::PrimaryDevice,0,-120)
 $wheel.RoutedEvent=[Windows.UIElement]::PreviewMouseWheelEvent
 $scroll.RaiseEvent($wheel);Pump
 $lines=[Windows.SystemParameters]::WheelScrollLines
 $expected=if($lines -lt 0){$scroll.ViewportHeight/2}else{$lines*($row.ActualHeight+$row.Margin.Top+$row.Margin.Bottom)/2}
 Assert ($wheel.Handled -and [Math]::Abs($scroll.VerticalOffset-$expected) -lt 1) 'One wheel notch scrolls half the normal logical row distance'
 $downOffset=$scroll.VerticalOffset
 $wheelUp=New-Object Windows.Input.MouseWheelEventArgs([Windows.Input.Mouse]::PrimaryDevice,0,120)
 $wheelUp.RoutedEvent=[Windows.UIElement]::PreviewMouseWheelEvent
 $scroll.RaiseEvent($wheelUp);Pump
 Assert ($scroll.VerticalOffset -lt $downOffset -and $scroll.VerticalOffset -eq 0) 'Reverse wheel scroll returns to top'
 for($i=0;$i -lt 4;$i++){
  $down=New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($picker),0,[Windows.Input.Key]::Down)
  $down.RoutedEvent=[Windows.UIElement]::KeyDownEvent
  $picker.RaiseEvent($down);Pump
 }
 $highlight=$picker.ItemContainerGenerator.ContainerFromIndex(4)
 Assert ($highlight.IsHighlighted -and $picker.SelectedIndex -eq 0) 'Keyboard focus highlights an uncommitted game'
 $tab=New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($highlight),0,[Windows.Input.Key]::Tab)
 $tab.RoutedEvent=[Windows.UIElement]::PreviewKeyDownEvent
 $highlight.RaiseEvent($tab);Pump
 Assert ($tab.Handled -and !$picker.IsDropDownOpen -and $picker.SelectedIndex -eq 4) 'Tab from popup item commits highlighted game and closes popup'
 Assert (![object]::ReferenceEquals([Windows.Input.Keyboard]::FocusedElement,$picker)) 'Tab advances focus after selection'
 $picker.IsDropDownOpen=$true;Pump
 $scroll.ScrollToVerticalOffset(0);Pump
 $wheelAgain=New-Object Windows.Input.MouseWheelEventArgs([Windows.Input.Mouse]::PrimaryDevice,0,-120)
 $wheelAgain.RoutedEvent=[Windows.UIElement]::PreviewMouseWheelEvent
 $scroll.RaiseEvent($wheelAgain);Pump
 Assert ([Math]::Abs($scroll.VerticalOffset-$expected) -lt 1) 'Reopening popup does not duplicate scroll handlers'
 $summary=[ordered]@{checksPassed=$checks;halfSpeedWheelVerified=$true;tabFromPopupItemCommitsSelection=$true;tabAdvancesFocus=$true;popupReopenVerified=$true;liveNetworkCalls=0}
 $summary|ConvertTo-Json|Set-Content "$bundle\game-picker-tests.json" -Encoding UTF8
 $summary|ConvertTo-Json
}finally{$window.Close()}

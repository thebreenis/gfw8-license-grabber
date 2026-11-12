using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

public static class Gfw8GamePickerBehavior {
 public static void Install(ComboBox picker) {
  picker.DropDownOpened += delegate {
   var scroll = picker.Template.FindName("GamePickerScroll", picker) as ScrollViewer;
   if (scroll == null || (bool)(scroll.Tag ?? false)) return;
   scroll.Tag = true;
   scroll.CanContentScroll = false;
   scroll.AddHandler(UIElement.PreviewMouseWheelEvent, new MouseWheelEventHandler(delegate(object sender, MouseWheelEventArgs e) {
    int lines = SystemParameters.WheelScrollLines;
    var firstItem = picker.ItemContainerGenerator.ContainerFromIndex(0) as ComboBoxItem;
    double rowHeight = firstItem != null && firstItem.ActualHeight > 0 ? firstItem.ActualHeight + firstItem.Margin.Top + firstItem.Margin.Bottom : 32.0;
    double distance = lines < 0 ? scroll.ViewportHeight : lines * rowHeight;
    scroll.ScrollToVerticalOffset(scroll.VerticalOffset - e.Delta / 120.0 * distance * 0.5);
    e.Handled = true;
   }), true);
  };
  picker.AddHandler(UIElement.PreviewKeyDownEvent, new KeyEventHandler(delegate(object sender, KeyEventArgs e) {
   if (e.Key != Key.Tab || !picker.IsDropDownOpen) return;
   // Keyboard navigation and mouse hover can highlight an uncommitted item.
   for (int i = 0; i < picker.Items.Count; i++) {
    var item = picker.ItemContainerGenerator.ContainerFromIndex(i) as ComboBoxItem;
    if (item != null && item.IsHighlighted) { picker.SelectedIndex = i; break; }
   }
   picker.IsDropDownOpen = false;
   e.Handled = true;
   picker.Focus();
   picker.MoveFocus(new TraversalRequest((Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? FocusNavigationDirection.Previous : FocusNavigationDirection.Next));
  }), true);
 }
}

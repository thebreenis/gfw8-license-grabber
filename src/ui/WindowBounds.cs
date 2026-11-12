using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

// Keep the custom-chrome window inside the current monitor's work area on maximize.
public static class Gfw8WindowBounds {
 [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
 [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public Rect Monitor, Work; public int Flags; }
 [StructLayout(LayoutKind.Sequential)] struct MinMaxInfo { public Point Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize; }
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
 [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
 public static void Install(Window window) {
  window.SourceInitialized += delegate {
   var source=HwndSource.FromHwnd(new WindowInteropHelper(window).Handle);
   if(source!=null) source.AddHook(BoundsHook);
  };
 }
 static IntPtr BoundsHook(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
  if(message==0x24 && lParam!=IntPtr.Zero) {
   var info=new MonitorInfo(); info.Size=Marshal.SizeOf(typeof(MonitorInfo));
   if(GetMonitorInfo(MonitorFromWindow(window,2),ref info)) {
    var bounds=(MinMaxInfo)Marshal.PtrToStructure(lParam,typeof(MinMaxInfo));
    bounds.MaxPosition.X=info.Work.Left-info.Monitor.Left;
    bounds.MaxPosition.Y=info.Work.Top-info.Monitor.Top;
    bounds.MaxSize.X=info.Work.Right-info.Work.Left;
    bounds.MaxSize.Y=info.Work.Bottom-info.Work.Top;
    Marshal.StructureToPtr(bounds,lParam,false);handled=true;
   }
  }
  return IntPtr.Zero;
 }
}

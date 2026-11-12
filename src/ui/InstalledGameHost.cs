using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class InstalledGameHost {
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern int GetPackageFamilyName(IntPtr process,ref uint length,StringBuilder family);
 public static string Family(int pid){
  IntPtr process=OpenProcess(0x1000,false,pid);if(process==IntPtr.Zero)return null;
  try{uint size=0;if(GetPackageFamilyName(process,ref size,null)!=122||size>1024)return null;var value=new StringBuilder((int)size);return GetPackageFamilyName(process,ref size,value)==0?value.ToString():null;}finally{CloseHandle(process);}
 }
 public static int[] Running(string family){
  var result=new List<int>();int session;using(var current=Process.GetCurrentProcess())session=current.SessionId;
  foreach(var process in Process.GetProcesses())using(process){try{if(process.SessionId==session&&String.Equals(Family(process.Id),family,StringComparison.OrdinalIgnoreCase))result.Add(process.Id);}catch{}}
  return result.ToArray();
 }
}

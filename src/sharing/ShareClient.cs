using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace Gfw8Sharing {
 public static class ShareClient {
  public static string DataRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"GFW8LicenseGrabber"); } }
  public static string Folder { get { return Path.Combine(DataRoot,"Sharing"); } }
  public static string Pipe(string folder) { return "GFW8Share-"+WindowsIdentity.GetCurrent().User.Value+"-"+Wire.Hash(Path.GetFullPath(folder).ToLowerInvariant()).Substring(0,12); }
  public static void PrivateFolder(string path) {
   Directory.CreateDirectory(path);var owner=WindowsIdentity.GetCurrent().User;var acl=new DirectorySecurity();acl.SetOwner(owner);acl.SetAccessRuleProtection(true,false);
   foreach(var sid in new[]{owner,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null)})acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
   Directory.SetAccessControl(path,acl);
  }
  public static Dictionary<string,object> CallAt(string folder,object command,int timeout=10000) {
   using(var pipe=new NamedPipeClientStream(".",Pipe(folder),PipeDirection.InOut,PipeOptions.Asynchronous)){
    pipe.Connect(timeout);var read=new StreamReader(pipe,Encoding.UTF8,false,4096,true);var write=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};
    write.WriteLine(Wire.Json.Serialize(command));var reading=read.ReadLineAsync();if(!reading.Wait(timeout))throw new TimeoutException("Sharing agent response timed out.");var line=reading.Result;if(line==null)throw new IOException("Sharing agent disconnected.");
    var result=Wire.Map(Wire.Json.DeserializeObject(line));if(Wire.Get(result,"success") is bool&&!(bool)result["success"])throw new InvalidOperationException(Wire.Text(result,"message"));return Wire.Map(Wire.Get(result,"data"));
   }
  }
  public static Dictionary<string,object> Call(object command,int timeout=10000) { return CallAt(Folder,command,timeout); }
  public static void Ensure(string runtime) {
   using(var mutex=new System.Threading.Mutex(false,"Local\\GFW8ShareInstall-"+WindowsIdentity.GetCurrent().User.Value)){
    bool locked=false;try{try{locked=mutex.WaitOne(60000);}catch(System.Threading.AbandonedMutexException){locked=true;}if(!locked)throw new IOException("Sharing agent update is still running.");EnsureCore(runtime);}finally{if(locked)mutex.ReleaseMutex();}
   }
  }
  static void EnsureCore(string runtime) {
   try{
    var current=Call(new{action="attach",pid=Process.GetCurrentProcess().Id},300);
    if(Wire.Text(current,"agentVersion")=="1.2.0")return;
    Call(new{action="stop"},5000);
    bool stopped=false;for(int n=0;n<600;n++){System.Threading.Thread.Sleep(100);try{Call(new{action="status"},100);}catch(IOException){stopped=true;break;}catch(TimeoutException){stopped=true;break;}}
    if(!stopped)throw new InvalidOperationException("The previous sharing agent is finishing an operation. Try again after it stops.");
    // The pipe can close just before the old process releases its executable.
    string installed=Path.Combine(Folder,"Agent","GFW8LG-Agent.exe");
    foreach(var process in Process.GetProcessesByName("GFW8LG-Agent")){
     try{if(String.Equals(process.MainModule.FileName,installed,StringComparison.OrdinalIgnoreCase)&&!process.WaitForExit(10000))throw new InvalidOperationException("The previous sharing agent is still shutting down. Try again shortly.");}
     catch(System.ComponentModel.Win32Exception){}finally{process.Dispose();}
    }
   }catch(IOException){}catch(TimeoutException){}
   PrivateFolder(DataRoot);PrivateFolder(Folder);string install=Path.Combine(Folder,"Agent");PrivateFolder(install);
   string source=Path.Combine(runtime,"GFW8LG-Agent.exe"),target=Path.Combine(install,"GFW8LG-Agent.exe");
   if(!File.Exists(source))throw new FileNotFoundException("Sharing agent is not bundled.");
   if(!File.Exists(target)||Hash(source)!=Hash(target))File.Copy(source,target,true);
   string settings=Path.Combine(Folder,"settings.json");
   if(!File.Exists(settings)){
    string relay=Wire.Text(Wire.Map(Wire.Json.DeserializeObject(File.ReadAllText(Path.Combine(runtime,"sharing-relay.json")))),"url");
    File.WriteAllText(settings,Wire.Json.Serialize(new{relayUrl=relay,label="My computer",background=false,paused=false}));
   }
   Process.Start(new ProcessStartInfo(target,"--owner "+Process.GetCurrentProcess().Id){UseShellExecute=false,CreateNoWindow=true});
   for(int i=0;i<100;i++){System.Threading.Thread.Sleep(100);try{Call(new{action="attach",pid=Process.GetCurrentProcess().Id},200);return;}catch(IOException){}catch(TimeoutException){}}
   throw new IOException("Sharing agent did not start.");
  }
  public static void AutoStartAsync(string runtime) { System.Threading.Tasks.Task.Run(()=>{try{AutoStart(runtime);}catch{}}); }
  public static void AutoStart(string runtime) { if(File.Exists(Path.Combine(Folder,"settings.json")))Ensure(runtime); }
  static string Hash(string path) { using(var file=File.OpenRead(path))using(var sha=SHA256.Create())return Convert.ToBase64String(sha.ComputeHash(file)); }
 }
}

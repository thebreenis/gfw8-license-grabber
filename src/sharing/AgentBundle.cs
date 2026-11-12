using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;


using System.Threading;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
static class AgentBundle {
 static string Hash(Stream stream){using(var sha=SHA256.Create()){return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","").ToLowerInvariant();}}
 static void PrivateDirectory(string path){
  Directory.CreateDirectory(path);
  var user=WindowsIdentity.GetCurrent().User;var acl=new DirectorySecurity();
  acl.SetOwner(user);acl.SetAccessRuleProtection(true,false);
  foreach(var sid in new[]{user,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null)})
   acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
  Directory.SetAccessControl(path,acl);
 }
 static bool Verify(ZipArchive zip,string root){
  foreach(var entry in zip.Entries){
   string path=SafePath(root,entry.FullName);
   if(!File.Exists(path))return false;
   using(var expected=entry.Open())using(var actual=File.OpenRead(path))if(Hash(expected)!=Hash(actual))return false;
  }
  return true;
 }
 static string SafePath(string root,string name){
  string path=Path.GetFullPath(Path.Combine(root,name.Replace('/',Path.DirectorySeparatorChar)));
  if(!path.StartsWith(Path.GetFullPath(root).TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Invalid bundled path.");
  return path;
 }
 public static string Unpack(){
  var assembly=Assembly.GetExecutingAssembly();
  using(var stream=assembly.GetManifestResourceStream("GFW8.Payload")){
   if(stream==null)throw new InvalidDataException("Bundled runtime is missing.");
   string payloadHash=Hash(stream);stream.Position=0;
   string data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"GFW8LicenseGrabber");
   PrivateDirectory(data);string runtime=Path.Combine(data,"Runtime");PrivateDirectory(runtime);
   string root=Path.Combine(runtime,"Agent-1.2.0-"+payloadHash.Substring(0,16));
   using(var zip=new ZipArchive(stream,ZipArchiveMode.Read)){
    if(Directory.Exists(root)&&Verify(zip,root))return root;
    // Preserve an unexpected/modified old cache; extract into a fresh private directory.
    if(Directory.Exists(root))root+="-"+Guid.NewGuid().ToString("N").Substring(0,8);
    PrivateDirectory(root);
    foreach(var entry in zip.Entries){
     string path=SafePath(root,entry.FullName);Directory.CreateDirectory(Path.GetDirectoryName(path));
     using(var input=entry.Open())using(var output=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None)){input.CopyTo(output);}
    }
    if(!Verify(zip,root))throw new InvalidDataException("Bundled runtime verification failed.");
   }
   return root;
  }
 }
}

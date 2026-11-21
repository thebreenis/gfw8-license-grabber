using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Gfw8Sharing {
 public static class ReceiptPaths {
  public static string DataRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GFW8LicenseGrabber"); } }
  public static void PrivateFolder(string path) {
   Directory.CreateDirectory(path);
   var owner = WindowsIdentity.GetCurrent().User;
   var acl = new DirectorySecurity();
   acl.SetOwner(owner); acl.SetAccessRuleProtection(true, false);
   foreach (var sid in new[] { owner, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
    acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
      InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
   Directory.SetAccessControl(path, acl);
  }
 }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace Gfw8Sharing {
 public static class Wire {
  public static JavaScriptSerializer Json { get { return new JavaScriptSerializer { MaxJsonLength = 2097152 }; } }
  public static Dictionary<string, object> Map(object o) { return o as Dictionary<string, object> ?? new Dictionary<string, object>(); }
  public static object Get(Dictionary<string, object> o,string k) { object v; return o.TryGetValue(k,out v)?v:null; }
  public static string Text(Dictionary<string, object> o,string k) { return Convert.ToString(Get(o,k)); }
  public static byte[] Utf(string s) { return Encoding.UTF8.GetBytes(s); }
  public static string B64(byte[] b) { return Convert.ToBase64String(b); }
  public static string Url(byte[] b) { return B64(b).TrimEnd('=').Replace('+','-').Replace('/','_'); }
  public static byte[] Unurl(string s) { s=s.Replace('-','+').Replace('_','/'); return Convert.FromBase64String(s+new string('=',(4-s.Length%4)%4)); }
  public static byte[] Random(int n) { var b=new byte[n];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(b);return b; }
  public static string Hash(string s) { using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(Utf(s))).Replace("-","").ToLowerInvariant(); }
  static byte[] Mac(byte[] key,string data) { using(var h=new HMACSHA256(key))return h.ComputeHash(Utf(data)); }
  static bool Equal(byte[] a,byte[] b) { if(a.Length!=b.Length)return false;int diff=0;for(int i=0;i<a.Length;i++)diff|=a[i]^b[i];return diff==0; }
  public static string Id(Dictionary<string,object> jwk) { return Hash(Text(jwk,"n")+"."+Text(jwk,"e")); }
  public static RSACng PublicKey(Dictionary<string,object> jwk) { var r=new RSACng();r.ImportParameters(new RSAParameters{Modulus=Unurl(Text(jwk,"n")),Exponent=Unurl(Text(jwk,"e"))});return r; }
  public static Dictionary<string,object> Seal(byte[] secret,string content) {
   byte[] aes=Mac(secret,"GFW8 sharing v1 encryption"),auth=Mac(secret,"GFW8 sharing v1 authentication"),iv=Random(16),cipher;
   using(var a=Aes.Create()){a.Key=aes;a.IV=iv;a.Mode=CipherMode.CBC;a.Padding=PaddingMode.PKCS7;using(var c=a.CreateEncryptor()){var p=Utf(content);cipher=c.TransformFinalBlock(p,0,p.Length);}}
   string i=B64(iv),d=B64(cipher);
   return new Dictionary<string,object>{{"iv",i},{"data",d},{"mac",B64(Mac(auth,i+"."+d))}};
  }
  public static string Open(byte[] secret,Dictionary<string,object> envelope) {
   string i=Text(envelope,"iv"),d=Text(envelope,"data");
   if(d.Length>1500000 || !Equal(Mac(Mac(secret,"GFW8 sharing v1 authentication"),i+"."+d),Convert.FromBase64String(Text(envelope,"mac"))))throw new CryptographicException("Encrypted message authentication failed.");
   using(var a=Aes.Create()){a.Key=Mac(secret,"GFW8 sharing v1 encryption");a.IV=Convert.FromBase64String(i);a.Mode=CipherMode.CBC;a.Padding=PaddingMode.PKCS7;using(var c=a.CreateDecryptor()){var b=Convert.FromBase64String(d);return Encoding.UTF8.GetString(c.TransformFinalBlock(b,0,b.Length));}}
  }
  static string Canon(Dictionary<string,object> p) { return Text(p,"from")+"|"+Text(p,"to")+"|"+Text(p,"pairId")+"|"+Text(p,"id")+"|"+Text(p,"time")+"|"+Text(p,"key")+"|"+Text(p,"iv")+"|"+Text(p,"data")+"|"+Text(p,"mac"); }
  public static string Encrypt(Identity sender,Dictionary<string,object> peer,string pairId,object value) {
   byte[] secret=Random(32),wrapped;using(var r=PublicKey(peer))wrapped=r.Encrypt(secret,RSAEncryptionPadding.OaepSHA256);
   var p=Seal(secret,Json.Serialize(value));p["from"]=sender.Id;p["to"]=Id(peer);p["pairId"]=pairId;p["id"]=Guid.NewGuid().ToString("N");p["time"]=DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();p["key"]=B64(wrapped);
   p["signature"]=sender.Sign(Canon(p));return Json.Serialize(p);
  }
  public static Dictionary<string,object> Decrypt(Identity receiver,Dictionary<string,object> peer,string pairId,string packet,out string nonce) {
   var p=Map(Json.DeserializeObject(packet));nonce=Text(p,"id");long time;
   if(Text(p,"from")!=Id(peer)||Text(p,"to")!=receiver.Id||Text(p,"pairId")!=pairId||!long.TryParse(Text(p,"time"),out time)||Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds()-time)>300)throw new CryptographicException("Wrong peer or expired encrypted message.");
   using(var r=PublicKey(peer)){if(!r.VerifyData(Utf(Canon(p)),Convert.FromBase64String(Text(p,"signature")),HashAlgorithmName.SHA256,RSASignaturePadding.Pss))throw new CryptographicException("Peer signature invalid.");}
   var secret=receiver.Decrypt(Convert.FromBase64String(Text(p,"key")));
   return Map(Json.DeserializeObject(Open(secret,p)));
  }
 }
 public sealed class Identity : IDisposable {
  readonly object gate=new object();
  public readonly RSACng Rsa; public readonly string Id; public readonly Dictionary<string,object> Jwk;
  public Identity(string folder) {
   Directory.CreateDirectory(folder); string path=Path.Combine(folder,"identity-protected.bin");Rsa=new RSACng(3072);
   if(File.Exists(path))Rsa.FromXmlString(Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(path),Wire.Utf("GFW8 sharing identity v1"),DataProtectionScope.CurrentUser)));
   else File.WriteAllBytes(path,ProtectedData.Protect(Wire.Utf(Rsa.ToXmlString(true)),Wire.Utf("GFW8 sharing identity v1"),DataProtectionScope.CurrentUser));
   var p=Rsa.ExportParameters(false);Jwk=new Dictionary<string,object>{{"kty","RSA"},{"n",Wire.Url(p.Modulus)},{"e",Wire.Url(p.Exponent)}};Id=Wire.Id(Jwk);
  }
  public string Sign(string text) { lock(gate)return Wire.B64(Rsa.SignData(Wire.Utf(text),HashAlgorithmName.SHA256,RSASignaturePadding.Pss)); }
  public byte[] Decrypt(byte[] data) { lock(gate)return Rsa.Decrypt(data,RSAEncryptionPadding.OaepSHA256); }
  public void Dispose() { Rsa.Dispose(); }
 }
}

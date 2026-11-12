// Synthetic transport/crypto tests. Never reads the user's receipt directories.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Gfw8Sharing;
class SharingTests {
 static int checks;
 static void Check(bool ok,string name){if(!ok)throw new Exception(name);Console.WriteLine("PASS "+name);checks++;}
 static Dictionary<string,object> Call(string root,object command){return ShareClient.CallAt(root,command,95000);}
 static Dictionary<string,object> Status(string root){return Call(root,new{action="status"});}
 static object[] Rows(Dictionary<string,object> s,string key){return Wire.Get(s,key) as object[]??new object[0];}
 static Dictionary<string,object> Peer(string root){return Rows(Status(root),"peers").Select(Wire.Map).FirstOrDefault();}
 static void Until(Func<bool> condition,string name){for(int i=0;i<150;i++){try{if(condition()){Check(true,name);return;}}catch{}Thread.Sleep(200);}throw new Exception("Timeout: "+name);}
 static Process Start(string exe,string root){return Process.Start(new ProcessStartInfo(exe,"--fixture --root \""+root+"\" --owner "+Process.GetCurrentProcess().Id){UseShellExecute=false,CreateNoWindow=true});}
 static void Stop(string root,Process p){try{Call(root,new{action="stop"});}catch{}if(!p.WaitForExit(15000))throw new Exception("Fixture agent did not stop gracefully.");}
 static int Main(string[] args){string testRoot=Path.GetFullPath(args[1]);Directory.CreateDirectory(testRoot);string a=Path.Combine(testRoot,"A"),b=Path.Combine(testRoot,"B"),c=Path.Combine(testRoot,"C");Process pa=null,pb=null,pc=null;try{
  foreach(string root in new[]{a,b,c}){ShareClient.PrivateFolder(root);File.WriteAllText(Path.Combine(root,"settings.json"),Wire.Json.Serialize(new{relayUrl=args.Length>2?args[2]:"http://127.0.0.1:8799",label=Path.GetFileName(root),background=true,paused=false}));}
  using(var one=new Identity(a))using(var two=new Identity(b)){
   string packet=Wire.Encrypt(one,two.Jwk,"test-pair",new{kind="test",value="private receipt text"});string nonce;
   Check(!packet.Contains("private receipt text"),"ciphertext hides receipt");Check(Wire.Text(Wire.Decrypt(two,one.Jwk,"test-pair",packet,out nonce),"value")=="private receipt text","signed encrypted round trip");
   bool rejected=false;try{Wire.Decrypt(two,one.Jwk,"wrong-pair",packet,out nonce);}catch{rejected=true;}Check(rejected,"reject wrong pair");
   var altered=Wire.Map(Wire.Json.DeserializeObject(packet));altered["data"]=Wire.B64(Wire.Random(32));rejected=false;try{Wire.Decrypt(two,one.Jwk,"test-pair",Wire.Json.Serialize(altered),out nonce);}catch{rejected=true;}Check(rejected,"reject modified ciphertext");
   using(var again=new Identity(a))Check(again.Id==one.Id,"DPAPI identity survives reload");
  }
  pa=Start(args[0],a);pb=Start(args[0],b);Until(()=>Wire.Text(Status(a),"state")=="Online"&&Wire.Text(Status(b),"state")=="Online","two agents authenticated");Until(()=>Rows(Status(a),"ownGames").Length==1,"synthetic inventory ready");
  string code=Wire.Text(Call(a,new{action="create",mode="temporary"}),"code");bool selfRejected=false;try{Call(a,new{action="join",code});}catch(Exception e){selfRejected=e.Message.Contains("yourself");}Check(selfRejected,"self-pairing rejected locally before replacing invitation");Call(b,new{action="join",code});Until(()=>Peer(a)!=null&&Peer(b)!=null&&Rows(Peer(b),"games").Length==1,"temporary pair exchanges catalogues");
  string pair=Wire.Text(Peer(b),"pairId");var receipt=Call(b,new{action="pull",pairId=pair,gameId=26});Check(Convert.ToInt32(Wire.Map(receipt["receipt"])["gameId"])==26,"temporary pull auto imports");
  Until(()=>Rows(Status(a),"activity").Any(r=>Wire.Text(Wire.Map(r),"message").Contains("saved and verified")),"sender receives saved-receipt confirmation");
  Check(Rows(Status(b),"activity").Any(r=>Wire.Text(Wire.Map(r),"message").Contains("Downloaded")),"recipient download activity recorded");
  Check(Rows(Status(a),"activity").Any(r=>Wire.Text(Wire.Map(r),"message").Contains("B connected")),"connection event recorded");
  long version=Convert.ToInt64(Peer(b)["catalogueVersion"]);int requests=Convert.ToInt32(Peer(b)["catalogueRequests"]);Call(b,new{action="refresh"});Thread.Sleep(250);Check(Convert.ToInt64(Peer(b)["catalogueVersion"])==version&&Convert.ToInt32(Peer(b)["catalogueRequests"])==requests,"status and own refresh do not refetch or rebuild friend catalogue");
  Call(a,new{action="fixture",gameIds=new[]{26,5}});Thread.Sleep(100);Check(Rows(Peer(b),"games").Length==1,"new licenses do not automatically replace connected snapshot");Call(b,new{action="refreshPeer",pairId=pair});Until(()=>Rows(Peer(b),"games").Length==2,"manual friend refresh loads new licenses");
  foreach(int id in new[]{26,5}){var saved=Call(b,new{action="pull",pairId=pair,gameId=id});Check(Convert.ToInt32(Wire.Map(saved["receipt"])["gameId"])==id,"selected multi-game transfer saves the requested edition "+id);}
  Call(a,new{action="fixture",gameIds=new[]{26}});Call(b,new{action="refreshPeer",pairId=pair});Until(()=>Rows(Peer(b),"games").Length==1,"manual friend refresh reconciles snapshot");
  Stop(b,pb);pb=null;Until(()=>Peer(a)==null,"temporary pair revoked on disconnect");
  Check(Rows(Status(a),"activity").Any(r=>Wire.Text(Wire.Map(r),"message").Contains("B disconnected")),"disconnect event recorded");
  pb=Start(args[0],b);Until(()=>Wire.Text(Status(b),"state")=="Online","recipient reconnects");
  code=Wire.Text(Call(a,new{action="create",mode="permanent"}),"code");Thread.Sleep(300);Call(b,new{action="join",code});Until(()=>Peer(a)!=null&&Peer(b)!=null&&Wire.Text(Peer(a),"mode")=="permanent","permanent pairing");
  Stop(a,pa);pa=null;Stop(b,pb);pb=null;
  pa=Start(args[0],a);pb=Start(args[0],b);Until(()=>Peer(a)!=null&&Peer(b)!=null&&Convert.ToBoolean(Peer(a)["online"])&&Rows(Peer(b),"games").Length==1,"permanent trust survives both process restarts");
  Check(Rows(Status(a),"activity").Any(r=>Wire.Text(Wire.Map(r),"message").Contains("saved and verified")),"transfer activity survives agent restart");
  pair=Wire.Text(Peer(b),"pairId");receipt=Call(b,new{action="pull",pairId=pair,gameId=26});Check(receipt.ContainsKey("receipt"),"background provider supplies receipt without UI");
  pc=Start(args[0],c);Until(()=>Wire.Text(Status(c),"state")=="Online","third agent authenticated");string thirdCode=Wire.Text(Call(a,new{action="create",mode="permanent"}),"code");Call(c,new{action="join",code=thirdCode});Until(()=>Peer(c)!=null&&Rows(Peer(c),"games").Length==1,"second friend paired");string thirdPair=Wire.Text(Peer(c),"pairId");var timer=Stopwatch.StartNew();var firstPull=Task.Run(()=>Call(b,new{action="pull",pairId=pair,gameId=26}));var secondPull=Task.Run(()=>Call(c,new{action="pull",pairId=thirdPair,gameId=26}));Task.WaitAll(firstPull,secondPull);timer.Stop();Check(firstPull.Result.ContainsKey("receipt")&&secondPull.Result.ContainsKey("receipt")&&Convert.ToInt32(Status(a)["maxObservedTransfers"])>=2,"two friends receive concurrent transfers");Check(timer.ElapsedMilliseconds<1900,"provider backend workers overlap instead of serializing two one-second jobs");Call(a,new{action="remove",pairId=thirdPair});Stop(c,pc);pc=null;
  Call(a,new{action="scan"});bool scanBlocked=false;try{Call(a,new{action="scan"});}catch{scanBlocked=true;}Check(scanBlocked,"duplicate scan prevented");Call(a,new{action="cancelScan"});Until(()=>!Convert.ToBoolean(Wire.Map(Status(a)["scan"])["running"]),"scan cancellation completes cooperatively");scanBlocked=false;try{Call(a,new{action="scan"});}catch{scanBlocked=true;}Check(scanBlocked,"scan cooldown persists after cancellation");Call(a,new{action="fixture",resetScanCooldown=true});Call(a,new{action="scan"});Until(()=>!Convert.ToBoolean(Wire.Map(Status(a)["scan"])["running"])&&Wire.Text(Wire.Map(Status(a)["catalogue"]),"lastScanUtc").Length>0,"completed scan updates freshness metadata");
  Call(a,new{action="fixture",suppressInvites=true});string waitingCode=Wire.Text(Call(a,new{action="create",mode="temporary"}),"code");var attempt=Task.Run(()=>Call(b,new{action="join",code=waitingCode}));Thread.Sleep(250);Call(b,new{action="cancelJoin"});bool cancelled=false;try{attempt.GetAwaiter().GetResult();}catch{cancelled=true;}Check(cancelled,"joining can be cancelled");string timeoutCode=Wire.Text(Call(a,new{action="create",mode="temporary"}),"code");var timeoutWatch=Stopwatch.StartNew();bool timedOut=false;try{Call(b,new{action="join",code=timeoutCode});}catch(Exception e){timedOut=e.Message.Contains("timed out");}Check(timedOut&&timeoutWatch.Elapsed.TotalSeconds>=29&&timeoutWatch.Elapsed.TotalSeconds<40,"unanswered pairing times out after 30 seconds");Call(a,new{action="fixture",suppressInvites=false});
  Call(a,new{action="settings",paused=true});Until(()=>Rows(Peer(b),"games").Length==0,"pause withdraws catalogue");bool denied=false;try{Call(b,new{action="pull",pairId=pair,gameId=26});}catch{denied=true;}Check(denied,"paused provider rejects cached pull");
  Call(a,new{action="settings",paused=false,sharedGameIds=new int[0]});Until(()=>Rows(Peer(b),"games").Length==0,"empty whitelist hides games");denied=false;try{Call(b,new{action="pull",pairId=pair,gameId=26});}catch{denied=true;}Check(denied,"unshared game cannot be pulled");
  Call(a,new{action="settings",sharedGameIds=new[]{26}});Call(b,new{action="refreshPeer",pairId=pair});Until(()=>Rows(Peer(b),"games").Length==1,"manual refresh restores selected shared game");
  Call(a,new{action="remove",pairId=pair});Until(()=>Peer(a)==null&&Peer(b)==null,"unpair revokes both sides");
  Console.WriteLine("Completed "+checks+" checks.");return 0;
 }catch(Exception e){Console.Error.WriteLine(e);return 1;}finally{if(pc!=null)Stop(c,pc);if(pa!=null)Stop(a,pa);if(pb!=null)Stop(b,pb);}}
}

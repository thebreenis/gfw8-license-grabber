using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Gfw8Sharing;

sealed partial class ReceiptAgent {
 readonly ConcurrentDictionary<string,TaskCompletionSource<Dictionary<string,object>>> controls=new ConcurrentDictionary<string,TaskCompletionSource<Dictionary<string,object>>>();
 readonly ConcurrentDictionary<string,TaskCompletionSource<Dictionary<string,object>>> pairWaits=new ConcurrentDictionary<string,TaskCompletionSource<Dictionary<string,object>>>();
 readonly SemaphoreSlim serveGate=new SemaphoreSlim(4);
 int activeServes,backendActive,maxObservedServes;
 volatile bool shutdownRequested,scanRunning,scanCancelRequested;
 string joinLookup="",pairingState="Ready",scanCancelPath="",scanState="Not running",scanGame="";
 int scanChecked,scanTotal=108,scanSaved,scanErrors;
 Dictionary<string,object> catalogueMetadata=new Dictionary<string,object>();

 void CheckShutdown(){if(shutdownRequested){CancelScan();if(!scanRunning&&activeServes==0&&backendActive==0){stop=true;try{socket.Abort();}catch{}}}}
 void CompleteControl(string id,Dictionary<string,object> value){TaskCompletionSource<Dictionary<string,object>> w;if(controls.TryGetValue(id,out w))w.TrySetResult(value);}
 void FailControl(string id,string error){TaskCompletionSource<Dictionary<string,object>> w;if(controls.TryGetValue(id,out w))w.TrySetException(new IOException(error));}
 void CompletePairWait(string lookup){TaskCompletionSource<Dictionary<string,object>> w;if(pairWaits.TryGetValue(lookup,out w)){pairingState="Paired successfully";w.TrySetResult(Status());}}
 void CancelPairWait(string lookup,string error){TaskCompletionSource<Dictionary<string,object>> w;if(pairWaits.TryGetValue(lookup,out w)){pairingState=error;w.TrySetException(new IOException(error));}}
 async Task CancelJoining(){string lookup;lock(gate)lookup=joinLookup;if(lookup.Length==0)return;CancelPairWait(lookup,"Pairing cancelled.");await Send(new{type="cancel",lookup});}
 async Task<Dictionary<string,object>> CreatePairCode(Dictionary<string,object> c){
  string mode=Wire.Text(c,"mode");if(mode!="temporary"&&mode!="permanent")throw new IOException("Select temporary or permanent.");
  byte[] secret=Wire.Random(24);string s=Wire.Url(secret),lookup=Wire.Hash("GFW8 invitation v1|"+s),rid=Guid.NewGuid().ToString("N");
  var wait=new TaskCompletionSource<Dictionary<string,object>>();controls[rid]=wait;
  lock(gate)invites[lookup]=new Dictionary<string,object>{{"secret",Wire.B64(secret)},{"mode",mode},{"owner",true},{"expires",DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds()}};
  try{await Send(new{type="create",lookup,mode,requestId=rid});if(await Task.WhenAny(wait.Task,Task.Delay(10000))!=wait.Task)throw new IOException("The relay did not confirm the code. Try again when online.");await wait.Task;pairingState="Code ready - give it to your friend";return new Dictionary<string,object>{{"code",(mode=="permanent"?"GFW8P-":"GFW8T-")+s},{"expiresMinutes",10}};}
  finally{TaskCompletionSource<Dictionary<string,object>> old;controls.TryRemove(rid,out old);}
 }
 async Task<Dictionary<string,object>> JoinPairCode(Dictionary<string,object> c){
  string code=Wire.Text(c,"code").Trim();if(!System.Text.RegularExpressions.Regex.IsMatch(code,@"^GFW8[PT]-[A-Za-z0-9_-]{32}$"))throw new IOException("Paste your friend's pairing code into Join Code.");
  string s=code.Substring(6),lookup=Wire.Hash("GFW8 invitation v1|"+s),mode=code[4]=='P'?"permanent":"temporary",nonce=Guid.NewGuid().ToString("N"),rid=Guid.NewGuid().ToString("N");byte[] secret=Wire.Unurl(s);
  lock(gate){Dictionary<string,object> old;if(invites.TryGetValue(lookup,out old)&&Wire.Get(old,"owner") is bool&&(bool)old["owner"])throw new IOException("This code belongs to this computer. Give it to your friend; you cannot pair with yourself.");if(joinLookup.Length>0)throw new IOException("Another pairing attempt is already running.");joinLookup=lookup;invites[lookup]=new Dictionary<string,object>{{"secret",Wire.B64(secret)},{"mode",mode},{"owner",false},{"nonce",nonce},{"expires",DateTimeOffset.UtcNow.AddMinutes(1).ToUnixTimeSeconds()}};}
  var wait=new TaskCompletionSource<Dictionary<string,object>>();controls[rid]=wait;pairWaits[lookup]=wait;pairingState="Joining - 30 second timeout";Exception failure=null;Dictionary<string,object> result=null;
  try{await Send(new{type="join",lookup,requestId=rid,envelope=Wire.Seal(secret,Wire.Json.Serialize(new{jwk=identity.Jwk,label=Label,mode,nonce}))});if(await Task.WhenAny(wait.Task,Task.Delay(30000))!=wait.Task)throw new IOException("Pairing timed out. Check that your friend is online and try a new code.");result=await wait.Task;}catch(Exception e){failure=e;}
  if(failure!=null){pairingState=failure.Message;lock(gate)invites.Remove(lookup);try{await Send(new{type="cancel",lookup});}catch{}}
  TaskCompletionSource<Dictionary<string,object>> unused;controls.TryRemove(rid,out unused);pairWaits.TryRemove(lookup,out unused);lock(gate)joinLookup="";
  if(failure!=null)throw failure;return result;
 }

 void QueueServe(string pair,string rid,int gameId){
  if(shutdownRequested){Task closing=SendFailure(pair,rid,"Provider is stopping.");return;}
  if(Interlocked.Increment(ref activeServes)>16){Interlocked.Decrement(ref activeServes);Task busy=SendFailure(pair,rid,"Provider is busy. Please try again shortly.");return;}
  Task serving=ServeReceipt(pair,rid,gameId);
 }
 async Task SendFailure(string pair,string rid,string message){try{await Packet(pair,new{kind="failure",requestId=rid,message});}catch{}}
 async Task ServeReceipt(string pair,string rid,int gameId){
  bool failed=false;await serveGate.WaitAsync();try{
   int active=4-serveGate.CurrentCount;int previous;do{previous=maxObservedServes;if(active<=previous)break;}while(Interlocked.CompareExchange(ref maxObservedServes,active,previous)!=previous);
   if(Paused||!Allowed(gameId)||!ownGames.Any(g=>Convert.ToInt32(Wire.Map(g)["gameId"])==gameId)){await SendFailure(pair,rid,"Game is not shared.");return;}
   var work=await Backend("receipt",new Dictionary<string,object>{{"gameId",gameId}});
   // Recheck revocation/pause after acquisition so queued requests cannot bypass a change.
   if(Paused||!Allowed(gameId)||!ownGames.Any(g=>Convert.ToInt32(Wire.Map(g)["gameId"])==gameId)){await SendFailure(pair,rid,"Sharing changed while this request was waiting.");return;}
   if(!(bool)work["success"]){backendState="Receipt unavailable: Windows sign-in, entitlement refresh or Microsoft cooldown may be required.";await SendFailure(pair,rid,"Provider could not supply a receipt. It may need sign-in or a cooldown.");return;}
   TrackDelivery(pair,rid,gameId);await Packet(pair,new{kind="receipt",requestId=rid,gameId,receipt=Wire.Text(Wire.Map(work["data"]),"receipt")});MarkSent(pair,rid);
  }catch{failed=true;AddActivity("Upload failed: "+GameLabel(gameId)+" to "+PeerLabel(pair)+".");}
  finally{serveGate.Release();Interlocked.Decrement(ref activeServes);}if(failed)await SendFailure(pair,rid,"Receipt transfer failed; please try again when both computers are online.");
 }

 void UpdateCatalogueMetadata(Dictionary<string,object> data){lock(gate){catalogueMetadata=new Dictionary<string,object>{{"lastScanUtc",Wire.Get(data,"lastScanUtc")},{"lastScanCatalogueHash",Wire.Get(data,"lastScanCatalogueHash")},{"currentCatalogueHash",Wire.Get(data,"currentCatalogueHash")},{"totalGames",Wire.Get(data,"totalGames")??108}};}}
 DateTime ScanNext(){DateTime value;lock(gate){DateTime next=DateTime.TryParse(Wire.Text(settings,"scanNotBeforeUtc"),null,System.Globalization.DateTimeStyles.RoundtripKind,out value)?value.ToUniversalTime():DateTime.MinValue;
#if SHARING_TESTS
  if(Fixture)return next;
#endif
  try{string path=Path.Combine(ShareClient.DataRoot,"full-scan-cooldown-private.json");if(File.Exists(path)){var record=Wire.Map(Wire.Json.DeserializeObject(File.ReadAllText(path)));if(DateTime.TryParse(Wire.Text(record,"nextAllowedUtc"),null,System.Globalization.DateTimeStyles.RoundtripKind,out value)&&value.ToUniversalTime()>next)next=value.ToUniversalTime();}}catch{}return next;}}
 Dictionary<string,object> ScanStatus(){return new Dictionary<string,object>{{"running",scanRunning},{"state",scanState},{"checked",scanChecked},{"total",scanTotal},{"saved",scanSaved},{"errors",scanErrors},{"game",scanGame},{"nextAllowedUtc",ScanNext()==DateTime.MinValue?"":ScanNext().ToString("o")}};}
 void StartScan(){lock(gate){if(shutdownRequested)throw new IOException("Agent is stopping.");if(scanRunning)throw new IOException("A license scan is already running.");if(DateTime.UtcNow<ScanNext())throw new IOException("Please wait until "+ScanNext().ToLocalTime().ToString("t")+" before another full scan. This is the app's precautionary cooldown, not a published Microsoft limit.");scanRunning=true;scanCancelRequested=false;scanCancelPath="";scanChecked=scanSaved=scanErrors=0;scanGame="";scanState="Scanning licenses";settings["scanNotBeforeUtc"]=DateTime.UtcNow.AddMinutes(15).ToString("o");SaveSettings();}Task scan=RunScan();}
 void CancelScan(){if(!scanRunning)return;scanCancelRequested=true;lock(gate){if(scanCancelPath.Length>0)File.WriteAllText(scanCancelPath,"cancel");}scanState="Cancelling after the current Microsoft request";}
 async Task RunScan(){try{var result=await Backend("scan");if(!(bool)result["success"]){scanState=Wire.Text(result,"message");return;}var bulk=Wire.Map(Wire.Get(Wire.Map(result["data"]),"bulk"));scanChecked=Convert.ToInt32(Wire.Get(bulk,"checked")??scanChecked);scanSaved=Convert.ToInt32(Wire.Get(bulk,"saved")??scanSaved);scanErrors=Convert.ToInt32(Wire.Get(bulk,"errors")??scanErrors);scanState=Wire.Get(bulk,"throttled") is bool&&(bool)bulk["throttled"]?"Microsoft throttled the scan - stopped":Wire.Get(bulk,"cancelled") is bool&&(bool)bulk["cancelled"]?"Scan cancelled":"Scan complete";await RefreshInventory();}catch{scanState="Scan failed; check Windows sign-in and try again later.";}finally{scanRunning=false;scanCancelPath="";}}
 void ReadScanEvents(string job){try{string path=Path.Combine(job,"events-private.jsonl");if(!File.Exists(path))return;string text;using(var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var reader=new StreamReader(input))text=reader.ReadToEnd();foreach(var line in text.Split('\n').Reverse()){if(String.IsNullOrWhiteSpace(line))continue;try{var row=Wire.Map(Wire.Json.DeserializeObject(line));if(Wire.Text(row,"kind")!="bulk")continue;scanChecked=Convert.ToInt32(row["done"]);scanTotal=Convert.ToInt32(row["total"]);scanSaved=Convert.ToInt32(row["saved"]);scanErrors=Convert.ToInt32(row["errors"]);scanGame=Wire.Text(row,"game");break;}catch{}}}catch{}}
#if SHARING_TESTS
 Dictionary<string,object> FixtureInventory(){var ids=Wire.Get(settings,"fixtureGameIds") as object[]??new object[]{26};return new Dictionary<string,object>{{"success",true},{"data",new Dictionary<string,object>{{"games",ids.Select(id=>(object)new Dictionary<string,object>{{"gameId",Convert.ToInt32(id)},{"name","Fixture Game "+id},{"fresh",true}}).ToArray()},{"lastScanUtc",Wire.Get(settings,"fixtureLastScanUtc")},{"lastScanCatalogueHash","fixture-v1"},{"currentCatalogueHash","fixture-v1"},{"totalGames",5}}}};}
 async Task<Dictionary<string,object>> FixtureScan(){for(int i=0;i<5&&!scanCancelRequested;i++){await Task.Delay(150);scanChecked=i+1;scanTotal=5;}if(!scanCancelRequested){settings["fixtureLastScanUtc"]=DateTime.UtcNow.ToString("o");SaveSettings();}return Wire.Map(Wire.Json.DeserializeObject("{\"success\":true,\"data\":{\"bulk\":{\"checked\":"+scanChecked+",\"saved\":1,\"errors\":0,\"cancelled\":"+(scanCancelRequested?"true":"false")+"}}}"));}
#endif
}

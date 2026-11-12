using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net.Http;
using System.Net.WebSockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;
using Gfw8Sharing;

[assembly:System.Reflection.AssemblyTitle("GFW8LG Receipt Sharing Agent")]
[assembly:System.Reflection.AssemblyCompany("Alec Breen | TheBreenis")]
[assembly:System.Reflection.AssemblyVersion("1.2.0.0")]
[assembly:System.Reflection.AssemblyFileVersion("1.2.0.0")]
sealed partial class ReceiptAgent {
 readonly string folder,runtime; readonly Identity identity; readonly object gate=new object();
 readonly SemaphoreSlim sendGate=new SemaphoreSlim(1),backendGate=new SemaphoreSlim(4);
 readonly ConcurrentDictionary<string,int> requestedGames=new ConcurrentDictionary<string,int>();
 readonly ConcurrentDictionary<string,TaskCompletionSource<Dictionary<string,object>>> pending=new ConcurrentDictionary<string,TaskCompletionSource<Dictionary<string,object>>>();
 readonly Dictionary<string,Dictionary<string,object>> peers=new Dictionary<string,Dictionary<string,object>>();
 readonly Dictionary<string,Dictionary<string,object>> invites=new Dictionary<string,Dictionary<string,object>>();
 readonly Dictionary<string,DateTime> seen=new Dictionary<string,DateTime>(); readonly HashSet<int> owners=new HashSet<int>();
 Dictionary<string,object> settings;object[] ownGames=new object[0];ClientWebSocket socket;volatile bool stop;string state="Connecting",backendState="Checking receipt availability";
 FileSystemWatcher watcher;DateTime inventoryDue=DateTime.MaxValue;
#if SHARING_TESTS
 public bool Fixture;bool suppressInvites;
#endif
 public ReceiptAgent(string path,string source,int owner){folder=path;runtime=source;ShareClient.PrivateFolder(path);identity=new Identity(path);settings=Wire.Map(Wire.Json.DeserializeObject(File.ReadAllText(Path.Combine(path,"settings.json"))));if(owner>0)owners.Add(owner);LoadPeers();LoadActivity();}
 void LoadPeers(){string path=Path.Combine(folder,"peers-protected.bin");if(!File.Exists(path))return;var bytes=ProtectedData.Unprotect(File.ReadAllBytes(path),Wire.Utf("GFW8 peers v1"),DataProtectionScope.CurrentUser);var all=Wire.Map(Wire.Json.DeserializeObject(Encoding.UTF8.GetString(bytes)));foreach(var p in all){peers[p.Key]=Wire.Map(p.Value);peers[p.Key]["online"]=false;peers[p.Key]["games"]=new object[0];}}
 void SavePeers(){lock(gate){var permanent=peers.Where(p=>Wire.Text(p.Value,"mode")=="permanent").ToDictionary(p=>p.Key,p=>(object)p.Value);File.WriteAllBytes(Path.Combine(folder,"peers-protected.bin"),ProtectedData.Protect(Wire.Utf(Wire.Json.Serialize(permanent)),Wire.Utf("GFW8 peers v1"),DataProtectionScope.CurrentUser));}}
 void SaveSettings(){lock(gate)File.WriteAllText(Path.Combine(folder,"settings.json"),Wire.Json.Serialize(settings));}
 string Label {get{lock(gate)return Wire.Text(settings,"label");}}
 bool Paused {get{lock(gate)return Wire.Get(settings,"paused") is bool&&(bool)settings["paused"];}}
 bool Allowed(int id){lock(gate){object a=Wire.Get(settings,"sharedGameIds");return a==null||((object[])a).Any(n=>Convert.ToInt32(n)==id);}}
 public void Stop(){shutdownRequested=true;CancelScan();CheckShutdown();}
 bool OwnerGone(){lock(gate){owners.RemoveWhere(p=>{try{return Process.GetProcessById(p).HasExited;}catch{return true;}});return owners.Count==0&&!(Wire.Get(settings,"background") is bool&&(bool)settings["background"]);}}
 void WatchInventory(){
#if SHARING_TESTS
  if(Fixture)return;
#endif
  watcher=new FileSystemWatcher(ShareClient.DataRoot,"receipt-proof-private.json"){IncludeSubdirectories=true,NotifyFilter=NotifyFilters.FileName|NotifyFilters.LastWrite};
  FileSystemEventHandler changed=delegate{lock(gate)inventoryDue=DateTime.UtcNow.AddSeconds(5);};watcher.Created+=changed;watcher.Changed+=changed;watcher.EnableRaisingEvents=true;
 }
 public async Task Run(){Task pipes=PipeLoop();Task inventory=RefreshInventory();WatchInventory();DateTime ping=DateTime.UtcNow;
  while(!stop){if(OwnerGone())shutdownRequested=true;CheckShutdown();if(stop)break;try{
   string url;lock(gate)url=Wire.Text(settings,"relayUrl").TrimEnd('/');var uri=new Uri(url);
   if(uri.Scheme!="https"&&!(uri.Scheme=="http"&&uri.IsLoopback))throw new InvalidOperationException("Relay must use HTTPS.");
   using(var http=new HttpClient()){http.Timeout=TimeSpan.FromSeconds(20);string prefix=url+"/device/"+identity.Id;
    var reg=await http.PostAsync(prefix+"/register",new StringContent(Wire.Json.Serialize(new{jwk=identity.Jwk,label=Label}),Encoding.UTF8,"application/json"));reg.EnsureSuccessStatusCode();
    var challenge=await http.PostAsync(prefix+"/challenge",new StringContent("{}"));challenge.EnsureSuccessStatusCode();var n=Wire.Map(Wire.Json.DeserializeObject(await challenge.Content.ReadAsStringAsync()));
    socket=new ClientWebSocket();socket.Options.KeepAliveInterval=TimeSpan.FromSeconds(30);socket.Options.SetRequestHeader("X-Nonce",Wire.Text(n,"nonce"));socket.Options.SetRequestHeader("X-Signature",identity.Sign("GFW8LG relay v1|"+identity.Id+"|"+Wire.Text(n,"nonce")));
    await socket.ConnectAsync(new Uri(prefix.Replace("https://","wss://").Replace("http://","ws://")+"/connect"),CancellationToken.None);state="Online";
    var receive=Receive();while(!receive.IsCompleted&&!stop){
     if(DateTime.UtcNow-ping>TimeSpan.FromMinutes(5)){await SendRaw("ping");ping=DateTime.UtcNow;}
     if(OwnerGone())shutdownRequested=true;CheckShutdown();
     bool refresh=false;lock(gate){if(DateTime.UtcNow>=inventoryDue&&inventory.IsCompleted&&!scanRunning){inventoryDue=DateTime.MaxValue;refresh=true;}}if(refresh)inventory=RefreshInventory();
     await Task.Delay(500);
    }
    if(stop){try{await socket.CloseAsync(WebSocketCloseStatus.NormalClosure,"Stopped",CancellationToken.None);}catch{socket.Abort();}}
    else await receive;
   }
  }catch{state="Offline - reconnecting";AllPeersOffline();}if(!stop)await Task.Delay(3000);}
  try{socket.Abort();}catch{};if(watcher!=null)watcher.Dispose();AllPeersOffline();state="Stopped";
 }
 async Task SendRaw(string text){await sendGate.WaitAsync();try{if(socket==null||socket.State!=WebSocketState.Open)throw new IOException("Relay is offline.");var b=Wire.Utf(text);await socket.SendAsync(new ArraySegment<byte>(b),WebSocketMessageType.Text,true,CancellationToken.None);}finally{sendGate.Release();}}
 Task Send(object value){return SendRaw(Wire.Json.Serialize(value));}
 async Task Receive(){var buffer=new byte[8192];while(socket.State==WebSocketState.Open&&!stop){using(var bytes=new MemoryStream()){WebSocketReceiveResult r;do{r=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),CancellationToken.None);if(r.MessageType==WebSocketMessageType.Close)return;bytes.Write(buffer,0,r.Count);if(bytes.Length>98304)throw new IOException("Relay message too large.");}while(!r.EndOfMessage);string text=Encoding.UTF8.GetString(bytes.ToArray());if(text=="pong")continue;try{await Message(Wire.Map(Wire.Json.DeserializeObject(text)));}catch{backendState="A received message failed authentication or validation.";}}}}
 async Task Packet(string pairId,object value){Dictionary<string,object> p;lock(gate){if(!peers.TryGetValue(pairId,out p))throw new IOException("Pair not trusted.");}await Send(new{type="packet",pairId,packet=Wire.Encrypt(identity,Wire.Map(p["jwk"]),pairId,value)});}
 async Task Catalogue(string pairId){object[] games;lock(gate)games=Paused?new object[0]:ownGames.Where(o=>Allowed(Convert.ToInt32(Wire.Map(o)["gameId"]))).ToArray();await Packet(pairId,new{kind="catalogue",games,paused=Paused});}
 async Task Message(Dictionary<string,object> m){string type=Wire.Text(m,"type"),pair=Wire.Text(m,"pairId");
  if(type=="welcome")return;
  if(type=="created"){CompleteControl(Wire.Text(m,"requestId"),m);return;}
  if(type=="cancelled"){CancelPairWait(pair,"Pairing cancelled.");lock(gate)invites.Remove(pair);return;}
  if(type=="peers"){
   var rows=Wire.Get(m,"items") as object[]??new object[0];var notify=new List<string>();lock(gate){var current=new HashSet<string>(rows.Select(r=>Wire.Text(Wire.Map(r),"pairId")));foreach(var gone in peers.Keys.Where(k=>!current.Contains(k)).ToArray()){PeerOnline(gone,peers[gone],false);peers.Remove(gone);}foreach(var row in rows){var r=Wire.Map(row);string id=Wire.Text(r,"pairId");Dictionary<string,object> p;if(peers.TryGetValue(id,out p)&&Wire.Text(p,"peerId")==Wire.Text(r,"peerId"))if(PeerOnline(id,p,Convert.ToBoolean(r["online"])))notify.Add(id);}}SavePeers();foreach(var id in notify){await Catalogue(id);await Packet(id,new{kind="getCatalogue"});}return;
  }
  if(type=="online"){var ids=new List<string>();lock(gate)foreach(var p in peers){if(Wire.Text(p.Value,"peerId")==Wire.Text(m,"peerId"))if(PeerOnline(p.Key,p.Value,Convert.ToBoolean(m["online"])))ids.Add(p.Key);}foreach(var id in ids){await Catalogue(id);await Packet(id,new{kind="getCatalogue"});}return;}
  if(type=="invitation"){
#if SHARING_TESTS
   if(Fixture&&suppressInvites)return;
#endif
   Dictionary<string,object> invite;lock(gate){if(!invites.TryGetValue(pair,out invite)||Convert.ToInt64(invite["expires"])<DateTimeOffset.UtcNow.ToUnixTimeSeconds())return;}
   var inner=Wire.Map(Wire.Json.DeserializeObject(Wire.Open(Convert.FromBase64String(Wire.Text(invite,"secret")),Wire.Map(m["envelope"]))));var jwk=Wire.Map(inner["jwk"]);
   if(Wire.Id(jwk)!=Wire.Text(m,"peerId")||Wire.Text(inner,"mode")!=Wire.Text(invite,"mode"))return;
   invite["peer"]=new Dictionary<string,object>{{"peerId",Wire.Id(jwk)},{"jwk",jwk},{"label",Wire.Text(inner,"label")},{"mode",Wire.Text(invite,"mode")},{"online",true}};
   var ack=Wire.Seal(Convert.FromBase64String(Wire.Text(invite,"secret")),Wire.Json.Serialize(new{jwk=identity.Jwk,label=Label,mode=Wire.Text(invite,"mode"),nonce=Wire.Text(inner,"nonce"),pairId=pair}));
   await Send(new{type="accept",lookup=pair,envelope=ack});return;
  }
  if(type=="accepted"||type=="acceptedOwner"){
   Dictionary<string,object> invite;lock(gate){if(!invites.TryGetValue(pair,out invite))return;}
   Dictionary<string,object> p;
   if(type=="acceptedOwner")p=Wire.Map(invite["peer"]);
   else{var inner=Wire.Map(Wire.Json.DeserializeObject(Wire.Open(Convert.FromBase64String(Wire.Text(invite,"secret")),Wire.Map(m["envelope"]))));var jwk=Wire.Map(inner["jwk"]);if(Wire.Id(jwk)!=Wire.Text(m,"peerId")||Wire.Text(inner,"nonce")!=Wire.Text(invite,"nonce")||Wire.Text(inner,"pairId")!=pair||Wire.Text(inner,"mode")!=Wire.Text(invite,"mode"))return;p=new Dictionary<string,object>{{"peerId",Wire.Id(jwk)},{"jwk",jwk},{"label",Wire.Text(inner,"label")},{"mode",Wire.Text(invite,"mode")},{"online",true}};}
   lock(gate){p["online"]=false;peers[pair]=p;PeerOnline(pair,p,true);invites.Remove(pair);}SavePeers();CompletePairWait(pair);await Catalogue(pair);await Packet(pair,new{kind="getCatalogue"});await Send(new{type="refresh"});return;
  }
  if(type=="removed"){lock(gate){if(peers.ContainsKey(pair))PeerOnline(pair,peers[pair],false);peers.Remove(pair);}SavePeers();return;}
  if(type=="error"){backendState=Wire.Text(m,"message");FailControl(Wire.Text(m,"requestId"),backendState);return;}
  if(type!="packet")return;
  Dictionary<string,object> peer;lock(gate){if(!peers.TryGetValue(pair,out peer)||Wire.Text(peer,"peerId")!=Wire.Text(m,"peerId"))return;}
  string nonce;var body=Wire.Decrypt(identity,Wire.Map(peer["jwk"]),pair,Wire.Text(m,"packet"),out nonce);
  lock(gate){foreach(var id in seen.Where(p=>DateTime.UtcNow-p.Value>TimeSpan.FromMinutes(6)).Select(p=>p.Key).ToArray())seen.Remove(id);if(seen.ContainsKey(nonce))return;seen[nonce]=DateTime.UtcNow;}
  string kind=Wire.Text(body,"kind"),rid=Wire.Text(body,"requestId");
  if(kind=="catalogue"){AcceptCatalogue(peer,body);return;}
  if(kind=="received"){ConfirmDelivery(pair,rid,Convert.ToInt32(body["gameId"]));return;}
  if(kind=="getCatalogue"){await Catalogue(pair);return;}
  if(kind=="pull"){QueueServe(pair,rid,Convert.ToInt32(body["gameId"]));return;}
  if(kind!="receipt"&&kind!="failure")return;
  string requestKey=pair+":"+rid;int expectedGame;TaskCompletionSource<Dictionary<string,object>> waiter;if(!requestedGames.TryRemove(requestKey,out expectedGame)||!pending.TryRemove(requestKey,out waiter))return;
  if(kind=="failure"){waiter.TrySetException(new IOException(Wire.Text(body,"message")));return;}
  if(kind=="receipt"){
   if(Convert.ToInt32(body["gameId"])!=expectedGame){waiter.TrySetException(new IOException("Peer returned a different game."));return;}
   var imported=await Backend("import",new Dictionary<string,object>{{"gameId",Convert.ToInt32(body["gameId"])},{"receipt",Wire.Text(body,"receipt")}});
   if((bool)imported["success"]){waiter.TrySetResult(Wire.Map(imported["data"]));try{await Packet(pair,new{kind="received",requestId=rid,gameId=expectedGame});}catch{}}else waiter.TrySetException(new IOException("Received receipt failed Microsoft signature, game or date validation."));
  }
 }
 async Task<Dictionary<string,object>> Backend(string action,Dictionary<string,object> extra=null){Interlocked.Increment(ref backendActive);await backendGate.WaitAsync();try{
#if SHARING_TESTS
  if(Fixture){if(action=="scan")return await FixtureScan();if(action=="receipt"){await Task.Delay(1000);}if(action=="inventory")return FixtureInventory();if(action=="receipt")return new Dictionary<string,object>{{"success",true},{"data",new Dictionary<string,object>{{"receipt",Wire.B64(Wire.Utf("SYNTHETIC SHARING RECEIPT"))}}}};return new Dictionary<string,object>{{"success",true},{"data",new Dictionary<string,object>{{"receipt",new Dictionary<string,object>{{"gameId",extra!=null&&extra.ContainsKey("gameId")?extra["gameId"]:(object)26},{"path","[fixture received receipt]"},{"proofPath","[fixture proof]"}}}}}};}
#endif
  string logs=Path.Combine(folder,"Jobs");ShareClient.PrivateFolder(logs);string job=Path.Combine(logs,Guid.NewGuid().ToString("N"));ShareClient.PrivateFolder(job);
  var request=new Dictionary<string,object>{{"action",action}};if(extra!=null)foreach(var p in extra)request[p.Key]=p.Value;
  if(action=="scan"){lock(gate)scanCancelPath=Path.Combine(job,"cancel.flag");request["cancelPath"]=scanCancelPath;if(scanCancelRequested)File.WriteAllText(scanCancelPath,"cancel");}
  string file=Path.Combine(job,"request-private.json");File.WriteAllText(file,Wire.Json.Serialize(request));
  string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");
  var start=new ProcessStartInfo(ps,"-NoProfile -MTA -ExecutionPolicy Bypass -File \""+Path.Combine(runtime,"SharingBackend.ps1")+"\" -RequestPath \""+file+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
  using(var process=Process.Start(start)){var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();while(!process.HasExited){if(action=="scan")ReadScanEvents(job);await Task.Delay(300);}if(action=="scan")ReadScanEvents(job);File.WriteAllText(Path.Combine(job,"worker-private.log"),(await output)+"\n"+(await error));}
  return Wire.Map(Wire.Json.DeserializeObject(File.ReadAllText(Path.Combine(job,"result-private.json"))));
 }finally{Interlocked.Decrement(ref backendActive);backendGate.Release();}}
 async Task RefreshInventory(){try{var r=await Backend("inventory");if(!(bool)r["success"]){backendState="Windows sign-in or local receipt acquisition is required to advertise games.";ownGames=new object[0];}else{var inventoryData=Wire.Map(r["data"]);ownGames=Wire.Get(inventoryData,"games") as object[]??new object[0];UpdateCatalogueMetadata(inventoryData);backendState="Ready";}}catch{backendState="Cannot read receipt availability.";}}
 public async Task<Dictionary<string,object>> Command(Dictionary<string,object> c){lock(gate)foreach(var key in invites.Keys.Where(k=>Convert.ToInt64(invites[k]["expires"])<DateTimeOffset.UtcNow.ToUnixTimeSeconds()).ToArray())invites.Remove(key);string action=Wire.Text(c,"action");
#if SHARING_TESTS
  if(Fixture&&action=="fixture"){if(c.ContainsKey("suppressInvites"))suppressInvites=Convert.ToBoolean(c["suppressInvites"]);if(c.ContainsKey("resetScanCooldown"))settings["scanNotBeforeUtc"]="";if(c.ContainsKey("gameIds")){settings["fixtureGameIds"]=c["gameIds"];await RefreshInventory();}return Status();}
#endif
  if(action=="attach"){lock(gate)owners.Add(Convert.ToInt32(c["pid"]));return Status();}
  if(action=="status")return Status();
  if(action=="refresh"){await RefreshInventory();if(socket!=null&&socket.State==WebSocketState.Open)await Send(new{type="refresh"});return Status();}
  if(action=="create")return await CreatePairCode(c);
  if(action=="join")return await JoinPairCode(c);
  if(action=="cancelJoin"){await CancelJoining();return Status();}
  if(action=="scan"){StartScan();return Status();}
  if(action=="cancelScan"){CancelScan();return Status();}
  if(action=="refreshPeer"){await RefreshPeer(Wire.Text(c,"pairId"));return Status();}
  if(action=="pull")return await PullReceipt(Wire.Text(c,"pairId"),Convert.ToInt32(c["gameId"]));
  if(action=="remove"){string pair=Wire.Text(c,"pairId");await Send(new{type="remove",pairId=pair});lock(gate){if(peers.ContainsKey(pair))PeerOnline(pair,peers[pair],false);peers.Remove(pair);}SavePeers();return Status();}
  if(action=="settings"){
   lock(gate){foreach(string key in new[]{"paused","background","label","sharedGameIds"})if(c.ContainsKey(key))settings[key]=c[key];}SaveSettings();
#if SHARING_TESTS
   if(!Fixture)
#endif
   using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")){if(Wire.Get(settings,"background") is bool&&(bool)settings["background"])key.SetValue("GFW8LicenseGrabberAgent","\""+Application.ExecutablePath+"\" --background");else key.DeleteValue("GFW8LicenseGrabberAgent",false);}
   await RefreshInventory();string[] notify;lock(gate)notify=peers.Where(p=>Wire.Get(p.Value,"online") is bool&&(bool)p.Value["online"]).Select(p=>p.Key).ToArray();foreach(var id in notify)await Catalogue(id);return Status();
  }
  if(action=="stop"){Stop();return new Dictionary<string,object>();}throw new IOException("Unknown sharing command.");
 }
 Dictionary<string,object> Status(){lock(gate)return new Dictionary<string,object>{{"agentVersion","1.2.0"},{"state",state},{"backendState",backendState},{"pairing",pairingState},{"scan",ScanStatus()},{"catalogue",catalogueMetadata},{"activeTransfers",activeServes},{"maxTransfers",4},{"maxObservedTransfers",maxObservedServes},{"deviceId",identity.Id},{"label",Label},{"paused",Paused},{"background",Wire.Get(settings,"background")??false},{"sharedGameIds",Wire.Get(settings,"sharedGameIds")},{"activity",ActivityRows()},{"activityRevision",activityRevision},{"ownGames",ownGames},{"peers",peers.Select(p=>new Dictionary<string,object>{{"pairId",p.Key},{"peerId",Wire.Text(p.Value,"peerId")},{"label",Wire.Text(p.Value,"label")},{"mode",Wire.Text(p.Value,"mode")},{"online",Wire.Get(p.Value,"online")??false},{"games",Wire.Get(p.Value,"games")??new object[0]},{"connectionGeneration",Wire.Get(p.Value,"connectionGeneration")??0},{"catalogueVersion",Wire.Get(p.Value,"catalogueVersion")??0},{"catalogueLoaded",Wire.Get(p.Value,"catalogueLoaded")??false},{"catalogueRequests",Wire.Get(p.Value,"catalogueRequests")??0}}).ToArray()}};}
 async Task PipeLoop(){while(!stop){var security=new PipeSecurity();var user=WindowsIdentity.GetCurrent().User;security.SetAccessRuleProtection(true,false);security.AddAccessRule(new PipeAccessRule(user,PipeAccessRights.FullControl,AccessControlType.Allow));var pipe=new NamedPipeServerStream(ShareClient.Pipe(folder),PipeDirection.InOut,32,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,security);
   await Task.Factory.FromAsync(pipe.BeginWaitForConnection,pipe.EndWaitForConnection,null);Task task=HandlePipe(pipe);
  }}
 async Task HandlePipe(NamedPipeServerStream pipe){using(pipe){try{var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true);var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};string line=await reader.ReadLineAsync();if(line==null||line.Length>32768)return;object result;try{result=new{success=true,data=await Command(Wire.Map(Wire.Json.DeserializeObject(line)))};}catch(Exception e){result=new{success=false,message=e is CryptographicException?"Message authentication failed.":e.Message};}await writer.WriteLineAsync(Wire.Json.Serialize(result));}catch{}}}
}
static class AgentMain {
 [STAThread] static int Main(string[] args){try{
  string folder=ShareClient.Folder;int owner=0;
  for(int i=0;i<args.Length;i++)if(args[i]=="--owner"&&i+1<args.Length)owner=int.Parse(args[++i]);
#if SHARING_TESTS
  for(int i=0;i<args.Length;i++)if(args[i]=="--root")folder=Path.GetFullPath(args[++i]);
#endif
  bool acquired;using(var mutex=new Mutex(true,"Local\\"+ShareClient.Pipe(folder),out acquired)){if(!acquired)return 0;try{
   if(args.Contains("--verify-bundle")){AgentBundle.Unpack();return 0;}
   string runtime;
#if SHARING_TESTS
   runtime=args.Contains("--fixture")?folder:AgentBundle.Unpack();
#else
   runtime=AgentBundle.Unpack();
#endif
   var agent=new ReceiptAgent(folder,runtime,owner);
#if SHARING_TESTS
   agent.Fixture=args.Contains("--fixture");
#endif
   var tray=new NotifyIcon{Icon=System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath),Text="GFW8 receipt sharing",Visible=true};var menu=new ContextMenuStrip();menu.Items.Add("Stop sharing agent",null,delegate{agent.Stop();});tray.ContextMenuStrip=menu;
   var work=Task.Run(()=>agent.Run());var timer=new System.Windows.Forms.Timer{Interval=500};timer.Tick+=delegate{if(work.IsCompleted)Application.ExitThread();};timer.Start();Application.Run();timer.Stop();tray.Dispose();return work.IsFaulted?1:0;
  }finally{mutex.ReleaseMutex();}}
 }catch{return 1;}}
}

using System;using System.Collections.Generic;using System.IO;using System.Linq;using System.Threading.Tasks;using Gfw8Sharing;
sealed partial class ReceiptAgent {
 readonly List<Dictionary<string,object>> activity=new List<Dictionary<string,object>>();long activityRevision;
 readonly Dictionary<string,Dictionary<string,object>> deliveries=new Dictionary<string,Dictionary<string,object>>();
 static string ActivityText(string value){return new string((value??"").Where(c=>!Char.IsControl(c)).Take(240).ToArray());}
 void LoadActivity(){try{string path=Path.Combine(folder,"sharing-activity-private.json");if(!File.Exists(path)||new FileInfo(path).Length>1048576)return;foreach(var raw in Wire.Json.DeserializeObject(File.ReadAllText(path)) as object[]??new object[0])activity.Add(Wire.Map(raw));if(activity.Count>200)activity.RemoveRange(0,activity.Count-200);activityRevision=1;}catch{activity.Clear();}}
 void SaveActivity(){try{string path=Path.Combine(folder,"sharing-activity-private.json"),temp=path+".tmp";File.WriteAllText(temp,Wire.Json.Serialize(activity));if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);}catch{}}
 void AddActivity(string message){lock(gate){activity.Add(new Dictionary<string,object>{{"utc",DateTime.UtcNow.ToString("o")},{"message",ActivityText(message)}});if(activity.Count>200)activity.RemoveAt(0);activityRevision++;SaveActivity();}}
 object[] ActivityRows(){lock(gate)return activity.Select(r=>(object)new Dictionary<string,object>(r)).ToArray();}
 string PeerLabel(string pair){lock(gate){Dictionary<string,object> p;return peers.TryGetValue(pair,out p)?ActivityText(Wire.Text(p,"label")):"Friend";}}
 string GameLabel(int gameId){lock(gate){foreach(var raw in ownGames.Concat(peers.Values.SelectMany(p=>Wire.Get(p,"games") as object[]??new object[0]))){var row=Wire.Map(raw);if(Convert.ToInt32(row["gameId"])==gameId)return ActivityText(Wire.Text(row,"name"));}return "Game "+gameId;}}
 bool PeerOnline(string pair,Dictionary<string,object> peer,bool online){
  bool previous=Wire.Get(peer,"online") is bool&&(bool)peer["online"];
  peer["online"]=online;
  if(previous!=online){
   AddActivity(ActivityText(Wire.Text(peer,"label"))+(online?" connected.":" disconnected."));
   if(online){peer["connectionGeneration"]=Convert.ToInt64(Wire.Get(peer,"connectionGeneration")??0)+1;peer["catalogueLoaded"]=false;peer["catalogueRequested"]=false;peer["games"]=new object[0];}
  }
  if(online&&!(Wire.Get(peer,"catalogueRequested") is bool&&(bool)peer["catalogueRequested"])){peer["catalogueRequested"]=true;peer["catalogueRequests"]=Convert.ToInt32(Wire.Get(peer,"catalogueRequests")??0)+1;return true;}return false;
 }
 void AllPeersOffline(){lock(gate)foreach(var p in peers)PeerOnline(p.Key,p.Value,false);}
 void AcceptCatalogue(Dictionary<string,object> peer,Dictionary<string,object> body){lock(gate){
  var incoming=Wire.Get(body,"games") as object[]??new object[0];bool loaded=Wire.Get(peer,"catalogueLoaded") is bool&&(bool)peer["catalogueLoaded"];
  object[] next=incoming;
  if(loaded){var ids=new HashSet<int>(incoming.Select(g=>Convert.ToInt32(Wire.Map(g)["gameId"])));next=(Wire.Get(peer,"games") as object[]??new object[0]).Where(g=>ids.Contains(Convert.ToInt32(Wire.Map(g)["gameId"]))).ToArray();}
  if(!loaded||Wire.Json.Serialize(next)!=Wire.Json.Serialize(Wire.Get(peer,"games"))){peer["games"]=next;peer["catalogueVersion"]=Convert.ToInt64(Wire.Get(peer,"catalogueVersion")??0)+1;}
  peer["catalogueLoaded"]=true;peer["paused"]=Wire.Get(body,"paused");
 }}
 async Task RefreshPeer(string pair){lock(gate){Dictionary<string,object> p;if(!peers.TryGetValue(pair,out p)||!(Wire.Get(p,"online") is bool&&(bool)p["online"]))throw new IOException("Friend is offline.");p["catalogueLoaded"]=false;p["catalogueRequests"]=Convert.ToInt32(Wire.Get(p,"catalogueRequests")??0)+1;}await Packet(pair,new{kind="getCatalogue"});}
 async Task<Dictionary<string,object>> PullReceipt(string pair,int gameId){
  string rid=Guid.NewGuid().ToString("N"),key=pair+":"+rid,label=PeerLabel(pair),game=GameLabel(gameId);var wait=new TaskCompletionSource<Dictionary<string,object>>();pending[key]=wait;requestedGames[key]=gameId;
  try{await Packet(pair,new{kind="pull",requestId=rid,gameId});if(await Task.WhenAny(wait.Task,Task.Delay(90000))!=wait.Task)throw new IOException("Peer did not supply a receipt. It may be offline or need sign-in.");var result=await wait.Task;AddActivity("Downloaded "+game+" from "+label+".");return result;}
  catch(Exception){AddActivity("Download failed: "+game+" from "+label+".");throw;}
  finally{TaskCompletionSource<Dictionary<string,object>> unused;pending.TryRemove(key,out unused);int number;requestedGames.TryRemove(key,out number);}
 }
 void TrackDelivery(string pair,string rid,int gameId){lock(gate){foreach(var key in deliveries.Where(p=>DateTime.UtcNow-DateTime.Parse(Wire.Text(p.Value,"utc")).ToUniversalTime()>TimeSpan.FromMinutes(5)).Select(p=>p.Key).ToArray())deliveries.Remove(key);if(deliveries.Count>=200)deliveries.Remove(deliveries.Keys.First());deliveries[pair+":"+rid]=new Dictionary<string,object>{{"gameId",gameId},{"game",GameLabel(gameId)},{"peer",PeerLabel(pair)},{"utc",DateTime.UtcNow.ToString("o")}};}}
 void ConfirmDelivery(string pair,string rid,int gameId){lock(gate){Dictionary<string,object> row;string key=pair+":"+rid;if(!deliveries.TryGetValue(key,out row)||Convert.ToInt32(row["gameId"])!=gameId)return;deliveries.Remove(key);AddActivity(Wire.Text(row,"peer")+" downloaded "+Wire.Text(row,"game")+" from you (saved and verified).");}}
 void MarkSent(string pair,string rid){lock(gate){Dictionary<string,object> row;if(deliveries.TryGetValue(pair+":"+rid,out row))AddActivity("Sent "+Wire.Text(row,"game")+" to "+Wire.Text(row,"peer")+" (awaiting save confirmation).");}}
}

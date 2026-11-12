using System;
using System.Collections.Generic;
using System.Linq;
using Gfw8Sharing;

static partial class Program {
 static Dictionary<string,object> Share(object command){return ShareClient.Call(command,95000);}
 static Dictionary<string,object>[] ShareRows(Dictionary<string,object> value,string key){return ((Get(value,key) as object[])??new object[0]).Select(Map).ToArray();}
 static Dictionary<string,object> ChoosePeer(Dictionary<string,object> status){var rows=ShareRows(status,"peers");for(int i=0;i<rows.Length;i++)Line("  "+(i+1)+" "+Safe(Text(rows[i],"label"))+" | "+Text(rows[i],"mode")+" | "+(Flag(rows[i],"online")?"Online":"Offline"));int choice;return Int32.TryParse(Prompt("Computer number:"),out choice)&&choice>0&&choice<=rows.Length?rows[choice-1]:null;}
 static void SharingMenu(){
  if(demo){Line("  Sharing is unavailable in demo mode.");return;}ShareClient.Ensure(runtime);
  Line("  Pair only with someone you trust. Joining allows both people to browse and pull shared receipts without further approval.",ConsoleColor.Yellow);
  while(true){var state=Share(new{action="status"});Tile("SHARING",ConsoleColor.DarkCyan);Line("  "+Text(state,"state")+" | "+Text(state,"backendState"));foreach(var p in ShareRows(state,"peers"))Line("  "+Safe(Text(p,"label"))+" | "+Text(p,"mode")+" | "+(Flag(p,"online")?"Online":"Offline")+" | "+ShareRows(p,"games").Length+" games");
   Line("  T Temporary Pairing Code  P Permanent Pairing Code  J Join Code");Line("  G Download receipts   R Refresh lists   L Transfer activity   X Unpair");Line("  B Background: "+(Flag(state,"background")?"On":"Off")+"  A Sharing: "+(Flag(state,"paused")?"Paused":"Active"));Line("  H Choose shared games  N Computer name  C Scan My Licenses  V Cancel Scan  0 Back");
   var scan=Map(Get(state,"scan"));var catalogue=Map(Get(state,"catalogue"));Line("  Scan: "+Text(scan,"state")+" "+Text(scan,"checked")+"/"+Text(scan,"total"));Line("  Last full scan: "+(Text(catalogue,"lastScanUtc").Length>0?LocalTime(Text(catalogue,"lastScanUtc")):"Not recorded for this account - scan to discover all licenses"));
   if(Text(catalogue,"lastScanCatalogueHash").Length>0&&!String.Equals(Text(catalogue,"lastScanCatalogueHash"),Text(catalogue,"currentCatalogueHash"),StringComparison.OrdinalIgnoreCase))Line("  Catalogue changed since your last scan; scan again to check new entries.",ConsoleColor.Yellow);
   string action=Prompt("Sharing:");if(action==null||action=="0")return;try{switch(action.Trim().ToLowerInvariant()){
    case "t":case "p":var code=Share(new{action="create",mode=action.ToLowerInvariant()=="p"?"permanent":"temporary"});Line("  "+Text(code,"code"),ConsoleColor.Cyan);Line("  Send this privately. Code expires in 10 minutes. Temporary pairs end on disconnect or after 2 hours.");break;
    case "j":string invite=Prompt("Pairing code:");if(!String.IsNullOrWhiteSpace(invite)){Share(new{action="join",code=invite});Line("  Paired successfully.");}break;
    case "r":Share(new{action="refresh"});foreach(var online in ShareRows(state,"peers").Where(p=>Flag(p,"online")))Share(new{action="refreshPeer",pairId=Text(online,"pairId")});break;
    case "l":foreach(var raw in ShareRows(state,"activity"))Line("  "+LocalTime(Text(raw,"utc"))+"  "+Text(raw,"message"));break;
    case "c":Line("  Checks every game with Microsoft, one at a time. Repeated scans may be throttled. The app enforces a 15-minute cooldown and stops on throttling.",ConsoleColor.Yellow);Share(new{action="scan"});Line("  Scan started; press Enter to update progress. Use V to cancel.");break;
    case "v":Share(new{action="cancelScan"});break;
    case "b":Share(new{action="settings",background=!Flag(state,"background")});break;
    case "a":Share(new{action="settings",paused=!Flag(state,"paused")});break;
    case "n":string label=Prompt("Computer name:");if(!String.IsNullOrWhiteSpace(label))Share(new{action="settings",label});break;
    case "h":foreach(var g in ShareRows(state,"ownGames"))Line("  "+Number(g,"gameId")+" "+Text(g,"name"));string ids=Prompt("Shared game IDs, comma separated, or ALL or NONE:");if(ids==null)break;int[] allowed=ids.Trim().Equals("all",StringComparison.OrdinalIgnoreCase)?ShareRows(state,"ownGames").Select(g=>Number(g,"gameId")).ToArray():ids.Trim().Equals("none",StringComparison.OrdinalIgnoreCase)?new int[0]:ids.Split(',').Select(x=>Int32.Parse(x.Trim())).ToArray();Share(new{action="settings",sharedGameIds=allowed});break;
    case "x":var remove=ChoosePeer(state);if(remove!=null)Share(new{action="remove",pairId=Text(remove,"pairId")});break;
    case "g":var peer=ChoosePeer(state);if(peer==null)break;var available=ShareRows(peer,"games");foreach(var g in available)Line("  "+Number(g,"gameId")+" "+Text(g,"name"));string query=Prompt("Game IDs separated by commas, or ALL:");if(String.IsNullOrWhiteSpace(query))break;int[] chosen=query.Trim().Equals("all",StringComparison.OrdinalIgnoreCase)?available.Select(g=>Number(g,"gameId")).ToArray():query.Split(',').Select(x=>Int32.Parse(x.Trim())).Distinct().ToArray();if(chosen.Any(id=>!available.Any(g=>Number(g,"gameId")==id)))throw new ArgumentException("Choose IDs from this friend's list.");foreach(int id in chosen){var result=Share(new{action="pull",pairId=Text(peer,"pairId"),gameId=id});receipt=Map(result["receipt"]);game=games.Single(g=>Number(g,"index")==Number(receipt,"gameId"));token=null;Line("  Receipt validated and saved: "+Text(receipt,"path"),ConsoleColor.Cyan);}break;
    default:Line("  Choose a sharing option.");break;
   }}catch(Exception e){Line("  "+Safe(e.Message),ConsoleColor.Red);}
  }
 }
}

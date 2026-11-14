using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static partial class Program {
 const string Version = "__CLI_VERSION__";
 static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 2097152 };
 static readonly string DataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GFW8LicenseGrabber");
 static string runtime, account = "Not read yet", gamertag = "Available after token acquisition";
 static bool demo, colour = true;
 static List<Dictionary<string, object>> games;
 static Dictionary<string, object> game, receipt, token;
 static readonly List<string> activity = new List<string>();
 static readonly object consoleLock = new object();
 static readonly HashSet<string> reportedErrors = new HashSet<string>(StringComparer.Ordinal);
 static ConsoleColor oldForeground, oldBackground;

 static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
 static object Get(Dictionary<string, object> map, string key) { object value; return map != null && map.TryGetValue(key, out value) ? value : null; }
 static string Text(Dictionary<string, object> map, string key) { return Convert.ToString(Get(map, key), CultureInfo.InvariantCulture); }
 static bool Flag(Dictionary<string, object> map, string key) { return Get(map, key) is bool && (bool)map[key]; }
 static int Number(Dictionary<string, object> map, string key) { return Convert.ToInt32(Get(map, key) ?? 0); }
 static string Safe(string text) {
  text = Regex.Replace(text ?? "", @"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[account]");
  text = Regex.Replace(text, @"(?i)xuid\([^)]*\)", "xuid(REDACTED)");
  text = text.Replace(DataRoot, "[saved files]");
  if (Regex.IsMatch(text, @"(?i)<jwt\b|WLID1\.0|XBL2\.0|Authorization\s*:")) return "[Credential detail omitted]";
  return text;
 }
 static void Line(string text, ConsoleColor foreground = ConsoleColor.Gray) {
  lock (consoleLock) {
   if (colour) { Console.BackgroundColor = ConsoleColor.Black; Console.ForegroundColor = foreground; }
   Console.WriteLine(text);
   if (colour) Console.ForegroundColor = ConsoleColor.White;
  }
 }
 static void Log(string text, ConsoleColor foreground = ConsoleColor.Gray) {
  string safe = Safe(text); activity.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + safe);
  Line("  " + safe, foreground);
 }
 static void ReportError(string text) {
  string safe = Safe(text);
  if (reportedErrors.Add(safe)) Log(safe, ConsoleColor.Red);
 }
 static void Tile(string text, ConsoleColor background) {
  lock (consoleLock) {
   if (colour) { Console.BackgroundColor = background; Console.ForegroundColor = ConsoleColor.White; }
   Console.Write("  " + text.PadRight(72));
   // Reset before the newline: terminal scrolling/line erasure uses the current
   // background colour and otherwise carries the tile colour onto the next row.
   if (colour) { Console.BackgroundColor = ConsoleColor.Black; Console.ForegroundColor = ConsoleColor.White; }
   Console.WriteLine();
  }
 }
 static void Header() {
  Line(""); Tile("GFW8 LICENSE GRABBER  |  CLI v" + Version, ConsoleColor.DarkMagenta);
  Line("  Alec Breen | TheBreenis  -  github.com/thebreenis/gfw8-license-grabber", ConsoleColor.DarkGray);
  if (demo) Line("  DEMO MODE - simulated results only; no account or network requests.", ConsoleColor.Yellow);
  Line("");
 }
 static string Prompt(string message) {
  lock (consoleLock) {
   if (colour) { Console.BackgroundColor = ConsoleColor.Black; Console.ForegroundColor = ConsoleColor.Cyan; }
   Console.Write("  " + message + " ");
   if (colour) Console.ForegroundColor = ConsoleColor.White;
  }
  return Console.ReadLine();
 }
 static bool Confirm(string message) {
  while (true) {
   string answer = Prompt(message + " [Y/N]");
   if (answer == null || answer.Equals("n", StringComparison.OrdinalIgnoreCase)) return false;
   if (answer.Equals("y", StringComparison.OrdinalIgnoreCase)) return true;
   Line("  Type Y or N.", ConsoleColor.Yellow);
  }
 }
 static string LocalTime(string value) {
  DateTimeOffset time;
  return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out time) ? time.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz") : value;
 }
 static string Hash(Stream stream) { using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(); }
 static void PrivateDirectory(string path) {
  Directory.CreateDirectory(path);
  var user = WindowsIdentity.GetCurrent().User;
  var acl = new DirectorySecurity(); acl.SetOwner(user); acl.SetAccessRuleProtection(true, false);
  foreach (var sid in new[] { user, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
   acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
  Directory.SetAccessControl(path, acl);
 }
 static string SafePath(string root, string name) {
  string path = Path.GetFullPath(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar)));
  if (!path.StartsWith(Path.GetFullPath(root).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid bundled path.");
  return path;
 }
 static bool Verify(ZipArchive zip, string root) {
  foreach (var entry in zip.Entries) {
   string path = SafePath(root, entry.FullName);
   if (!File.Exists(path)) return false;
   using (var expected = entry.Open()) using (var actual = File.OpenRead(path)) if (Hash(expected) != Hash(actual)) return false;
  }
  return true;
 }
 static string Unpack() {
  using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("GFW8.Payload")) {
   if (stream == null) throw new InvalidDataException("Bundled runtime is missing.");
   string hash = Hash(stream); stream.Position = 0;
   PrivateDirectory(DataRoot); string cache = Path.Combine(DataRoot, "Runtime"); PrivateDirectory(cache);
   string root = Path.Combine(cache, "CLI-" + Version + "-" + hash.Substring(0, 16));
   using (var zip = new ZipArchive(stream, ZipArchiveMode.Read)) {
    if (Directory.Exists(root) && Verify(zip, root)) return root;
    if (Directory.Exists(root)) root += "-" + Guid.NewGuid().ToString("N").Substring(0, 8);
    PrivateDirectory(root);
    foreach (var entry in zip.Entries) {
     string path = SafePath(root, entry.FullName); Directory.CreateDirectory(Path.GetDirectoryName(path));
     using (var input = entry.Open()) using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output);
    }
    if (!Verify(zip, root)) throw new InvalidDataException("Bundled runtime verification failed.");
   }
   return root;
  }
 }
 static string Quote(string value) {
  var result = new StringBuilder("\""); int slashes = 0;
  foreach (char ch in value) {
   if (ch == '\\') { slashes++; continue; }
   if (ch == '"') { result.Append('\\', slashes * 2 + 1); result.Append(ch); }
   else { result.Append('\\', slashes); result.Append(ch); }
   slashes = 0;
  }
  result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
 }
 static void Event(Dictionary<string, object> row) {
  string kind = Text(row, "kind");
  if (kind == "account") {
   if (row.ContainsKey("email")) account = Text(row, "email");
   if (!String.IsNullOrEmpty(Text(row, "gamertag"))) gamertag = Text(row, "gamertag");
  } else if (kind == "log") {
   if (Text(row, "level") == "error") ReportError(Text(row, "text"));
   else Log(Text(row, "text"), Text(row, "level") == "warning" ? ConsoleColor.Yellow : ConsoleColor.Gray);
  }
  else if (kind == "stage") Line("  > " + Safe(Text(row, "text")), ConsoleColor.Cyan);
  else if (kind == "bulk") Line(String.Format("  [{0}/108]  Saved {1}   Unlicensed {2}   Errors {3}", Number(row, "done"), Number(row, "saved"), Number(row, "unlicensed"), Number(row, "errors")), ConsoleColor.Cyan);
 }
 static Dictionary<string, object> Worker(string action, Dictionary<string, object> extra = null) {
  reportedErrors.Clear();
  if (demo) return DemoWorker(action, extra);
  string logRoot = Path.Combine(DataRoot, action.StartsWith("installer") ? "ReceiptInstaller" : "Logs"); PrivateDirectory(logRoot);
  string cliRoot = Path.Combine(logRoot, "CLI"); PrivateDirectory(cliRoot);
  string job = Path.Combine(cliRoot, DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff") + "-" + Guid.NewGuid().ToString("N").Substring(0, 8)); PrivateDirectory(job);
  var request = new Dictionary<string, object> { { "action", action }, { "gameId", Number(game, "index") }, { "storeAccount", account == "Not read yet" ? "" : account } };
  if (extra != null) foreach (var item in extra) request[item.Key] = item.Value;
  string requestPath = Path.Combine(job, "request-private.json"); File.WriteAllText(requestPath, Json.Serialize(request), new UTF8Encoding(false));
  string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
  var start = new ProcessStartInfo(ps, "-NoProfile -MTA -ExecutionPolicy Bypass -File " + Quote(Path.Combine(runtime, "Worker.ps1")) + " -RequestPath " + Quote(requestPath));
  start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
  using (var process = new Process { StartInfo = start }) {
   process.Start(); var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
   ConsoleCancelEventHandler cancel = delegate(object sender, ConsoleCancelEventArgs e) {
    e.Cancel = true;
    if (action == "bulk" || action.StartsWith("installer")) { File.WriteAllText(Path.Combine(job, "cancel.flag"), "cancel"); Line("\n  Cancel requested. Finishing this receipt request first.", ConsoleColor.Yellow); }
    else Line("\n  Waiting for authentication/cleanup. Complete or cancel the Windows sign-in prompt.", ConsoleColor.Yellow);
   };
   Console.CancelKeyPress += cancel;
   StreamReader reader = null; string pending = "";
   Action readEvents = delegate {
    string path = Path.Combine(job, "events.jsonl");
    if (reader == null && File.Exists(path)) reader = new StreamReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite));
    if (reader == null) return;
    pending += reader.ReadToEnd(); int newline;
    while ((newline = pending.IndexOf('\n')) >= 0) {
     string line = pending.Substring(0, newline).Trim(); pending = pending.Substring(newline + 1);
     if (line.Length != 0) Event(Map(Json.DeserializeObject(line)));
    }
   };
   try {
    while (!process.WaitForExit(100)) readEvents();
    readEvents();
    File.WriteAllText(Path.Combine(job, "worker-stdout-private.log"), stdout.GetAwaiter().GetResult());
    File.WriteAllText(Path.Combine(job, "worker-stderr-private.log"), stderr.GetAwaiter().GetResult());
    File.WriteAllLines(Path.Combine(job, "activity.txt"), activity.ToArray());
    string resultPath = Path.Combine(job, "result.json");
    if (!File.Exists(resultPath)) throw new IOException("Worker did not save a result. Private diagnostics: " + job);
    return Map(Json.DeserializeObject(File.ReadAllText(resultPath)));
   } finally { Console.CancelKeyPress -= cancel; if (reader != null) reader.Dispose(); }
  }
 }
 static int ErrorCode(Dictionary<string, object> result) {
  if (Flag(Map(Get(result, "data")), "cancelled")) { Log("Operation cancelled; completed results retained.", ConsoleColor.Yellow); return 5; }
  if (Flag(result, "success")) return 0;
  ReportError(Text(result, "message"));
  return Flag(result, "unlicensed") ? 3 : Flag(result, "installedBlocked") ? 4 : 1;
 }
 static int Account() { gamertag = "Available after token acquisition"; var result = Worker("account"); if (ErrorCode(result) != 0) return 1; Line("  Microsoft account: " + account); Line("  Xbox profile: " + gamertag); return 0; }
 static bool SelectGame(string query) {
  int id; var found = games.Where(g => Int32.TryParse(query, out id) ? Number(g, "index") == id : Text(g, "name").IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0).ToList();
  if (found.Count != 1) { ListGames(query); Line("  Enter one unique game name or its number.", ConsoleColor.Yellow); return false; }
  game = found[0]; receipt = null; token = null; Line("  Selected: " + Text(game, "name"), ConsoleColor.Cyan); return true;
 }
 static void ListGames(string query = "") {
  foreach (var item in games.Where(g => String.IsNullOrEmpty(query) || Text(g, "name").IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || Number(g, "index").ToString() == query))
   Line(String.Format("  {0,3}  {1}", Number(item, "index"), Text(item, "name")));
 }
 static int Status() {
  var result = Worker("availability"); int error = ErrorCode(result); if (error != 0) return error;
  Line("  " + Text(game, "name") + ": " + (Flag(Map(Get(result, "data")), "installed") ? "installed - receipts only" : "uninstalled - token/Presence available")); return 0;
 }
 static int Receipt(string importPath = null) {
  receipt = null; token = null;
  var result = Worker(importPath == null ? "receipt" : "load", importPath == null ? null : new Dictionary<string, object> { { "path", Path.GetFullPath(importPath) } });
  int error = ErrorCode(result); if (error != 0) return error;
  receipt = Map(Get(Map(Get(result, "data")), "receipt"));
  int id = Number(receipt, "gameId"); game = games.Single(g => Number(g, "index") == id);
  Line("  " + Text(game, "name") + " receipt: " + Text(receipt, "path"), ConsoleColor.Cyan);
  Line("  Issued: " + LocalTime(Text(receipt, "mintedUtc")) + "    Expires: " + LocalTime(Text(receipt, "expiresUtc"))); return 0;
 }
 static int Token() {
  token = null; gamertag = "Available after token acquisition";
  if (receipt == null) { Line("  Get or import a valid receipt first.", ConsoleColor.Yellow); return 2; }
  var result = Worker("token", new Dictionary<string, object> { { "proofPath", Text(receipt, "proofPath") } });
  int error = ErrorCode(result); if (error != 0) return error;
  token = Map(Get(Map(Get(result, "data")), "token"));
  Line("  Token saved: " + Text(token, "exportPath"), ConsoleColor.Magenta);
  Line("  Expires: " + LocalTime(Text(token, "expiresUtc")));
  if (!String.IsNullOrEmpty(Text(token, "gamertag"))) gamertag = Text(token, "gamertag");
  if (Flag(token, "dataPreservationAlert")) Line("  Data-preservation alert: inspect the retained before/after records.", ConsoleColor.Yellow);
  return 0;
 }
 static int Presence(bool interactive) {
  if (token == null) { Line("  Acquire a token for this game first.", ConsoleColor.Yellow); return 2; }
  if (interactive && !Confirm("Test Xbox Presence and submit Last Played history?")) return 0;
  var result = Worker("presence", new Dictionary<string, object> { { "token", token } });
  int error = ErrorCode(result); if (error != 0) return error;
  var view = Map(Get(Map(Get(result, "data")), "presence"));
  Line("  Presence accepted: " + Flag(view, "presenceWriteAccepted") + "   Active readback: " + Flag(view, "activeReadback"), ConsoleColor.Green);
  if (Flag(view, "cleanupRequired")) Line("  Temporary Presence removed: " + (Flag(view, "cleanupAccepted") && Flag(view, "targetAbsentAfterCleanup")));
  if (!Flag(view, "presenceWriteAccepted") || !Flag(view, "activeReadback") || (Flag(view, "cleanupRequired") && (!Flag(view, "cleanupAccepted") || !Flag(view, "targetAbsentAfterCleanup")))) return 1;
  return 0;
 }
 static int Bulk() {
  Tile("BULK RECEIPTS  |  Ctrl+C cancels between completed requests", ConsoleColor.DarkCyan);
  var result = Worker("bulk"); int error = ErrorCode(result); if (error != 0) return error;
  var data = Map(Get(result, "data")); var bulk = Map(Get(data, "bulk"));
  Line(String.Format("  Checked {0}/108   Saved {1}   Unlicensed {2}   Errors {3}", Number(bulk, "checked"), Number(bulk, "saved"), Number(bulk, "unlicensed"), Number(bulk, "errors")), ConsoleColor.Cyan);
  Line("  Batch log: " + Text(data, "run"));
  if (Flag(bulk, "cancelled")) return 5;
  return Number(bulk, "errors") == 0 ? 0 : 1;
 }
 static void CopyToken() {
  if (token == null || demo) { Line("  No real token available to copy.", ConsoleColor.Yellow); return; }
  string export = Path.GetFullPath(Text(token, "exportPath"));
  if (!export.StartsWith(DataRoot.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Token export is outside private storage.");
  Clipboard.SetText(File.ReadAllText(Path.Combine(export, "issued-token.xml"))); Line("  Saved token XML copied to clipboard.", ConsoleColor.Magenta);
 }
 static void SaveLog() {
  if (demo) { Line("  Demo activity was not saved."); return; }
  string logs = Path.Combine(DataRoot, "Logs"); PrivateDirectory(logs);
  string path = Path.Combine(logs, "CLI-activity-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff") + ".txt");
  File.WriteAllLines(path, activity.ToArray()); Line("  Activity saved: " + path);
 }
 static int Menu() {
  if (!demo) Account();
  while (true) {
   Line(""); Line("  Game: " + Text(game, "name") + "   |   Xbox: " + gamertag, ConsoleColor.White);
   Tile("RECEIPT", ConsoleColor.DarkCyan); Line("  1 Select game     2 Get pop.bin     3 Import pop.bin");
   Tile("TOKEN", ConsoleColor.DarkMagenta); Line("  4 Get Xbox token  9 Copy token XML");
   Tile("PRESENCE", ConsoleColor.DarkGreen); Line("  5 Test Presence + Last Played");
   Line("  6 Bulk receipts  7 Open saved files  8 Account/status");
   Line("  I Install receipts   S Receipt sharing  L Save activity log  0 Exit");
   string choice = Prompt("Choose:"); if (choice == null || choice == "0") return 0;
   try {
    switch (choice.Trim().ToLowerInvariant()) {
     case "1": string query = Prompt("Game name, number, or ? to list:"); if (query == null) break; if (query == "?") { ListGames(); query = Prompt("Game name or number:"); } if (!String.IsNullOrWhiteSpace(query)) SelectGame(query); break;
     case "2": Receipt(); break;
     case "3": string path = Prompt("Path to pop.bin:"); if (!String.IsNullOrWhiteSpace(path)) Receipt(path.Trim('"')); break;
     case "4": Token(); break;
     case "5": Presence(true); break;
     case "6": Bulk(); break;
     case "7": if (!demo) Process.Start("explorer.exe", Quote(DataRoot)); break;
     case "8": Account(); Status(); break;
     case "9": CopyToken(); break;
     case "l": SaveLog(); break;
     case "s": SharingMenu(); break;
     case "i": InstallReceipts(); break;
     default: Line("  Choose one of the menu options.", ConsoleColor.Yellow); break;
    }
   } catch (Exception e) { Log(e.Message, ConsoleColor.Red); }
  }
 }
 static void InstallReceipts() {
  if(demo){Line("  Receipt installation is unavailable in demo mode.");return;}
  string source=Prompt("Folder, ZIP, or 7z containing pop.bin files:");if(String.IsNullOrWhiteSpace(source))return;
  var result=Worker("installerScan",new Dictionary<string,object>{{"source",source.Trim('"')}});if(ErrorCode(result)!=0)return;var data=Map(Get(result,"data"));
  Line(Text(data,"message"));if(Flag(data,"cancelled"))return;var rows=Get(data,"entries") as object[]??new object[0];foreach(var raw in rows){var row=Map(raw);Line("  "+Text(row,"game")+" | "+(Flag(row,"installed")?"Installed":"Not installed")+" | "+Text(row,"destination"));}
  foreach(var raw in Get(data,"issues") as object[]??new object[0]){var row=Map(raw);Line("  Skipped: "+Text(row,"source")+" - "+Text(row,"message"),ConsoleColor.Yellow);}
  if(rows.Length==0)return;bool include=false;if(rows.Any(x=>!Flag(Map(x),"installed"))){while(true){string answer=Prompt("Install receipts for games that are not installed? [Y/N]");if(answer==null)return;if(answer.Equals("y",StringComparison.OrdinalIgnoreCase)){include=true;break;}if(answer.Equals("n",StringComparison.OrdinalIgnoreCase))break;Line("  Type Y or N.");}}
  if(!rows.Any(x=>include||Flag(Map(x),"installed")))return;string confirm=Prompt("Install the listed receipts now? Existing receipts will be replaced. [Y/N]");if(!String.Equals(confirm,"y",StringComparison.OrdinalIgnoreCase))return;
  result=Worker("installerApply",new Dictionary<string,object>{{"planPath",Text(data,"planPath")},{"includeUninstalled",include}});if(ErrorCode(result)==0){data=Map(Get(result,"data"));Line(Text(data,"message"));foreach(var raw in Get(data,"entries") as object[]??new object[0]){var row=Map(raw);Line("  "+Text(row,"game")+": "+Text(row,"message"));}}
 }
 static void Help() {
  Header();
  Line("  No arguments: interactive menu. Flags work in CMD or PowerShell.\n");
  Line("  --list                     List all 108 games without signing in");
  Line("  --game <number or name>     Select a game (quote names with spaces)");
  Line("  --receipt                  Acquire a fresh pop.bin");
  Line("  --import <path>            Validate/import a receipt; auto-select game");
  Line("  --token                    Use the receipt acquired/imported in this run");
  Line("  --presence                 Test Presence + Last Played after --token");
  Line("  --bulk                     Receipts only for all 108 games; Ctrl+C cancels");
  Line("  --sharing                  Pair, browse and pull receipts; background options\n  --status                   Read-only installation status for selected game");
  Line("  --version  --help  --no-color  --demo\n");
  Line("  Examples:");
  Line("    \"GFW8LG-CLI v" + Version + ".exe\" --game 26 --receipt --token");
  Line("    \"GFW8LG-CLI v" + Version + ".exe\" --import \"D:\\Receipts\\pop.bin\" --token --presence");
  Line("    \"GFW8LG-CLI v" + Version + ".exe\" --bulk\n");
  Line("  Installed games: receipts only. Bulk never requests tokens.");
  Line("  Exit codes: 0 success, 1 error, 2 usage/missing receipt, 3 no license,");
  Line("              4 installed-game guard, 5 operation cancelled.");
 }
 static Dictionary<string, object> DemoWorker(string action, Dictionary<string, object> extra) {
  var result = new Dictionary<string, object> { { "success", true } }; var data = new Dictionary<string, object>(); result["data"] = data;
  string now = DateTimeOffset.UtcNow.ToString("o");
  Log("DEMO: " + action + " (simulated; no network requests).", ConsoleColor.DarkGray);
  if (action == "account") { account = "player@example.com"; gamertag = "PlayerOne"; }
  else if (action == "availability") data["installed"] = false;
  else if (action == "receipt" || action == "load") data["receipt"] = new Dictionary<string, object> { { "gameId", Number(game, "index") }, { "path", "[demo receipt - not a real file]" }, { "proofPath", "demo" }, { "mintedUtc", now }, { "expiresUtc", DateTimeOffset.UtcNow.AddHours(24).ToString("o") } };
  else if (action == "token") data["token"] = new Dictionary<string, object> { { "gameId", Number(game, "index") }, { "exportPath", "[demo token - not a real file]" }, { "expiresUtc", DateTimeOffset.UtcNow.AddHours(4).ToString("o") }, { "gamertag", "PlayerOne" } };
  else if (action == "presence") data["presence"] = new Dictionary<string, object> { { "presenceWriteAccepted", true }, { "activeReadback", true }, { "cleanupRequired", true }, { "cleanupAccepted", true }, { "targetAbsentAfterCleanup", true } };
  else if (action == "bulk") { data["bulk"] = new Dictionary<string, object> { { "checked", 108 }, { "saved", 16 }, { "unlicensed", 92 }, { "errors", 0 }, { "cancelled", false } }; data["run"] = "[demo batch log - not a real file]"; }
  return result;
 }
 [STAThread] static int Main(string[] args) {
  oldForeground = Console.ForegroundColor; oldBackground = Console.BackgroundColor;
  colour = !args.Contains("--no-color") && !Console.IsOutputRedirected;
  try {
   Console.Title = "GFW8 License Grabber CLI v" + Version + " | Alec Breen | TheBreenis";
   if (colour) { Console.BackgroundColor = ConsoleColor.Black; Console.ForegroundColor = ConsoleColor.White; }
   if (args.Contains("--version")) { Line("GFW8 License Grabber CLI v" + Version + " | Alec Breen | TheBreenis"); return 0; }
   if (args.Contains("--help") || args.Contains("-h")) { Help(); return 0; }
   string select = null, import = null, verifyPath = null; bool sharing = false, list = false, getReceipt = false, getToken = false, presence = false, bulk = false, status = false;
   for (int i = 0; i < args.Length; i++) {
    switch (args[i]) {
     case "--demo": demo = true; break;
     case "--no-color": break;
     case "--list": list = true; break;
     case "--sharing": sharing = true; break;
     case "--receipt": getReceipt = true; break;
     case "--token": getToken = true; break;
     case "--presence": presence = true; break;
     case "--bulk": bulk = true; break;
     case "--status": status = true; break;
     case "--game": case "--import": case "--verify-bundle":
      string option = args[i]; if (++i >= args.Length) throw new ArgumentException(option + " needs a value.");
      if (option == "--game") select = args[i]; else if (option == "--import") import = args[i]; else verifyPath = args[i]; break;
     default: throw new ArgumentException("Unknown option: " + args[i] + ". Use --help.");
    }
   }
   if (bulk && (getReceipt || getToken || presence || import != null || select != null || status || list)) throw new ArgumentException("--bulk is receipts-only and cannot be combined with game, receipt, token or Presence options.");
   if (getReceipt && import != null) throw new ArgumentException("Choose --receipt or --import.");
   if (sharing && (bulk || list || getReceipt || getToken || presence || status || select != null || import != null)) throw new ArgumentException("Use --sharing by itself to open the sharing menu.");
   if (presence && !getToken) throw new ArgumentException("--presence requires --token in the same run.");
   if (getToken && !getReceipt && import == null) throw new ArgumentException("Use --receipt or --import with --token.");
   bool acquired;
   using (var mutex = new Mutex(true, (demo || list || verifyPath != null ? "Local\\GFW8LG-ReadOnly-" + Process.GetCurrentProcess().Id : "Local\\GFW8LicenseGrabber-" + WindowsIdentity.GetCurrent().User.Value), out acquired)) {
    if (!acquired) { Line("Close the running GUI/CLI before starting another operation.", ConsoleColor.Yellow); return 1; }
    try {
     runtime = Unpack();
     if (verifyPath != null) { File.WriteAllText(Path.GetFullPath(verifyPath), Json.Serialize(new { bundleVerified = true, runtimeRoot = runtime, version = Version })); return 0; }
     var catalogue = Map(Json.DeserializeObject(File.ReadAllText(Path.Combine(runtime, "backend/games.json"))));
     games = ((object[])catalogue["games"]).Select(Map).ToList(); game = games[0];
     Header(); if (select != null && !SelectGame(select)) return 2;
     if (list) { ListGames(); return 0; }
     if (bulk) return Bulk();
     if (!demo && !status) Gfw8Sharing.ShareClient.AutoStartAsync(runtime);
     if (sharing) { SharingMenu(); return 0; }
     bool command = getReceipt || import != null || getToken || presence || status;
     if (!command) return Menu();
     if ((getReceipt || status) && select == null && import == null) throw new ArgumentException("Choose --game for this operation.");
     int error;
     if (getReceipt || import != null) { error = Receipt(import); if (error != 0) return error; }
     if (status) { error = Status(); if (error != 0) return error; }
     if (getToken) { error = Token(); if (error != 0) return error; }
     if (presence) return Presence(false);
     return 0;
    } finally { mutex.ReleaseMutex(); }
   }
  } catch (ArgumentException e) { Line("  " + e.Message, ConsoleColor.Red); return 2; }
    catch (Exception e) { Line("  " + Safe(e.Message), ConsoleColor.Red); return 1; }
  finally { if (colour) { Console.ForegroundColor = oldForeground; Console.BackgroundColor = oldBackground; } }
 }
}

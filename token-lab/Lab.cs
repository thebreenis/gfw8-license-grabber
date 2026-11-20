using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Gfw8Sharing;

static class Lab {
 internal const string Version="0.1.3";
 internal static readonly string Home=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"GFW8TokenLab");
 internal static readonly JavaScriptSerializer Json=new JavaScriptSerializer{MaxJsonLength=16*1024*1024};
 internal static void PrivateDirectory(string path){
  Directory.CreateDirectory(path);var owner=WindowsIdentity.GetCurrent().User;var acl=new DirectorySecurity();acl.SetOwner(owner);acl.SetAccessRuleProtection(true,false);
  foreach(var sid in new[]{owner,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null)})acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
  Directory.SetAccessControl(path,acl);
 }
 static string Hash(Stream s){using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(s)).Replace("-","").ToLowerInvariant();}
 static string SafePath(string root,string name){string path=Path.GetFullPath(Path.Combine(root,name.Replace('/',Path.DirectorySeparatorChar)));if(!path.StartsWith(Path.GetFullPath(root).TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Invalid runtime entry.");return path;}
 static bool Verify(ZipArchive zip,string root){foreach(var e in zip.Entries){string p=SafePath(root,e.FullName);if(!File.Exists(p))return false;using(var a=e.Open())using(var b=File.OpenRead(p))if(Hash(a)!=Hash(b))return false;}return true;}
 internal static string Unpack(){
  PrivateDirectory(Home);PrivateDirectory(Path.Combine(Home,"Runtime"));
  using(var input=Assembly.GetExecutingAssembly().GetManifestResourceStream("Lab.Payload")){
   if(input==null)throw new InvalidDataException("Runtime bundle missing.");string hash=Hash(input);input.Position=0;string root=Path.Combine(Home,"Runtime",Version+"-"+hash.Substring(0,16));
   using(var zip=new ZipArchive(input,ZipArchiveMode.Read)){
    if(Directory.Exists(root)&&Verify(zip,root))return root;
    if(Directory.Exists(root))root+="-"+Guid.NewGuid().ToString("N");PrivateDirectory(root);
    foreach(var e in zip.Entries){string path=SafePath(root,e.FullName);Directory.CreateDirectory(Path.GetDirectoryName(path));using(var a=e.Open())using(var b=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None))a.CopyTo(b);}
    if(!Verify(zip,root))throw new InvalidDataException("Runtime bundle verification failed.");return root;
   }
  }
 }
 [STAThread] static int Main(string[] args){
  try{
   if(args.Length==2&&args[0]=="--verify-bundle"){string root=Unpack();File.WriteAllText(Path.GetFullPath(args[1]),Json.Serialize(new{verified=true,runtime=root,version=Version}));return 0;}
   Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
   if(args.Length==1&&args[0]=="--self-test"){using(var f=new LabWindow(Unpack()))f.SelfTest();return 0;}
   bool acquired;using(var instance=new Mutex(true,"Local\\GFW8TokenLab-"+WindowsIdentity.GetCurrent().User.Value,out acquired)){
    if(!acquired){MessageBox.Show("GFW8 Token Lab is already open.","GFW8 Token Lab");return 1;}
    try{Application.Run(new LabWindow(Unpack()));}finally{instance.ReleaseMutex();}
   }return 0;
  }catch(Exception e){if(args.Length>0){Console.Error.WriteLine(e.ToString());}else MessageBox.Show("Token Lab could not start ("+e.GetType().Name+"). Rebuild or extract a fresh copy.","GFW8 Token Lab");return 1;}
 }
}

sealed class LabWindow:Form {
 readonly string runtime;readonly Color purple=Color.FromArgb(31,9,40),panel=Color.FromArgb(43,28,52),cyan=Color.FromArgb(0,164,188);
 readonly Button pull,saved,single,stop,open,copy;readonly CheckBox prompts;readonly Label status,stage;readonly ProgressBar progress;readonly DataGridView table;readonly RichTextBox activity;readonly System.Windows.Forms.Timer timer;
 readonly Dictionary<int,DataGridViewRow> rows=new Dictionary<int,DataGridViewRow>();
 Process worker;TextWriter workerLog;string job="",lastJob="";int eventLines;bool complete,stopRequested;Mutex appMutex;bool appLock;
 public LabWindow(string root){
  runtime=root;Text="GFW8 Token Lab";BackColor=purple;ForeColor=Color.White;Font=new Font("Segoe UI",10);StartPosition=FormStartPosition.CenterScreen;ClientSize=new Size(1240,820);MinimumSize=new Size(1120,740);FormBorderStyle=FormBorderStyle.None;
  Icon=new Icon(Path.Combine(runtime,"App.ico"));
  var layout=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=7,Padding=new Padding(20,0,20,12)};
  layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
  layout.RowStyles.Add(new RowStyle(SizeType.Absolute,67));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,44));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,58));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,51));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,37));layout.RowStyles.Add(new RowStyle(SizeType.Percent,100));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,34));Controls.Add(layout);
  var chrome=MetroChrome.Create(this,"GFW8 Token Lab",()=>WindowState=WindowState==FormWindowState.Maximized?FormWindowState.Normal:FormWindowState.Maximized);chrome.Dock=DockStyle.Fill;layout.Controls.Add(chrome,0,0);
  layout.Controls.Add(new Label{Dock=DockStyle.Fill,Text="DEV TOOLS  /  RECEIPTS + TOKEN DIAGNOSTICS\nSame catalogue and authentication backend as GFW8 License Grabber. Separate app; local reports.",AutoSize=false,ForeColor=Color.FromArgb(170,220,224),Margin=new Padding(0)},0,1);
  var actions=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0),Padding=new Padding(0,6,0,0)};
  pull=Tile("Pull all receipts + test tokens",285,cyan,()=>Start("pull"));saved=Tile("Test all saved receipts",230,Color.FromArgb(156,0,216),()=>Start("saved"));single=Tile("Test a single receipt",210,Color.FromArgb(173,52,28),TestSingle);
  open=Tile("Open reports",140,Color.FromArgb(65,125,15),OpenReports);copy=Tile("Copy failures",140,panel,CopyFailures);
  actions.Controls.AddRange(new Control[]{pull,saved,single,open,copy});layout.Controls.Add(actions,0,2);
  var options=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,Margin=new Padding(0)};options.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));options.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,240));
  prompts=new CheckBox{Dock=DockStyle.Fill,Text="Allow Windows sign-in prompts if needed (off = unattended, silent attempts)",Checked=true,AutoSize=false,Margin=new Padding(0,3,8,0)};options.Controls.Add(prompts,0,0);
  stop=Tile("Stop Current Process",230,Color.FromArgb(173,52,28),Cancel);stop.Dock=DockStyle.Fill;stop.Margin=new Padding(8,3,0,5);stop.Enabled=false;options.Controls.Add(stop,1,0);layout.Controls.Add(options,0,3);
  var state=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,Margin=new Padding(0)};state.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));state.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,280));stage=new Label{Dock=DockStyle.Fill,Text="Ready. Receipts use the shared 15-minute full-scan cooldown.",ForeColor=Color.Cyan,TextAlign=ContentAlignment.MiddleLeft};progress=new ProgressBar{Dock=DockStyle.Fill,Margin=new Padding(10,10,0,9)};state.Controls.Add(stage,0,0);state.Controls.Add(progress,1,0);layout.Controls.Add(state,0,4);
  var split=new SplitContainer{Dock=DockStyle.Fill,Orientation=Orientation.Horizontal,BackColor=purple,SplitterWidth=8};layout.Controls.Add(split,0,5);
  table=new DataGridView{Dock=DockStyle.Fill,ReadOnly=true,AllowUserToAddRows=false,AllowUserToDeleteRows=false,AllowUserToResizeRows=false,RowHeadersVisible=false,BackgroundColor=panel,BorderStyle=BorderStyle.None,GridColor=Color.FromArgb(65,42,76),AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill,SelectionMode=DataGridViewSelectionMode.FullRowSelect,MultiSelect=false,EnableHeadersVisualStyles=false};
  table.ColumnHeadersDefaultCellStyle=new DataGridViewCellStyle{BackColor=cyan,ForeColor=Color.White,Font=new Font("Segoe UI",10,FontStyle.Bold),Padding=new Padding(2,5,2,5)};
  table.ColumnHeadersHeightSizeMode=DataGridViewColumnHeadersHeightSizeMode.DisableResizing;table.ColumnHeadersHeight=38;
  table.DefaultCellStyle=new DataGridViewCellStyle{BackColor=panel,ForeColor=Color.White,SelectionBackColor=Color.FromArgb(73,40,88),SelectionForeColor=Color.White,Padding=new Padding(2)};table.AlternatingRowsDefaultCellStyle.BackColor=Color.FromArgb(36,23,45);table.RowTemplate.Height=30;
  foreach(var c in new[]{new[]{"game","Game","28"},new[]{"receipt","Receipt","13"},new[]{"licenseType","Trial / Full","12"},new[]{"token","Token result","27"},new[]{"code","Error code","14"},new[]{"cleanup","Helper cleanup","18"}}){int i=table.Columns.Add(c[0],c[1]);table.Columns[i].FillWeight=Int32.Parse(c[2]);table.Columns[i].SortMode=DataGridViewColumnSortMode.NotSortable;}
  table.CellClick+=delegate(object s,DataGridViewCellEventArgs e){if(e.RowIndex>=0){var r=table.Rows[e.RowIndex].Tag as Dictionary<string,object>;if(r!=null)Log(TextOf(r,"game")+": "+TextOf(r,"message"),Color.LightCyan);}};
  split.Panel1.Controls.Add(table);activity=new RichTextBox{Dock=DockStyle.Fill,ReadOnly=true,BackColor=Color.FromArgb(19,14,25),ForeColor=Color.Gainsboro,BorderStyle=BorderStyle.None,Font=new Font("Consolas",10),DetectUrls=false};split.Panel2.Controls.Add(activity);
  var footer=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,Margin=new Padding(0)};footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,320));status=new Label{Dock=DockStyle.Fill,Text="No run started.",TextAlign=ContentAlignment.MiddleLeft};footer.Controls.Add(status,0,0);footer.Controls.Add(new Label{Dock=DockStyle.Fill,Text="Alec Breen | TheBreenis    v"+Lab.Version,TextAlign=ContentAlignment.MiddleRight,ForeColor=Color.FromArgb(177,156,186)},1,0);layout.Controls.Add(footer,0,6);
  Shown+=delegate{split.SplitterDistance=(int)(split.Height*.64);Log("Pull checks the full catalogue through Microsoft. Repeated requests may be throttled; there is no guaranteed safe request rate.",Color.LightCyan);Log("Installed games are skipped. No Presence or achievement writes. Token contents and raw diagnostics stay in private saved files.",Color.Gainsboro);};
  timer=new System.Windows.Forms.Timer{Interval=500};timer.Tick+=delegate{Poll();};timer.Start();
  FormClosing+=delegate(object s,FormClosingEventArgs e){if(worker!=null){Cancel();e.Cancel=true;Log("Waiting for the current operation and helper cleanup before closing.",Color.Yellow);}};
 }
 Button Tile(string text,int width,Color color,Action action){var b=new Button{Text=text,Width=width,Height=43,BackColor=color,ForeColor=Color.White,FlatStyle=FlatStyle.Flat,Margin=new Padding(0,0,8,0),Padding=new Padding(7,0,7,0),Font=new Font("Segoe UI",10)};b.FlatAppearance.BorderSize=1;b.FlatAppearance.BorderColor=Color.FromArgb(155,130,167);b.Click+=delegate{action();};return b;}
 static string TextOf(Dictionary<string,object> d,string key){object v;return d.TryGetValue(key,out v)&&v!=null?Convert.ToString(v):"";}
 void Log(string text,Color color){if(activity.TextLength>150000)activity.Clear();activity.SelectionStart=activity.TextLength;activity.SelectionColor=color;activity.AppendText(DateTime.Now.ToString("HH:mm:ss")+"  "+text+Environment.NewLine);activity.ScrollToCaret();}
 void TestSingle(){
  if(worker!=null)return;
  using(var picker=new OpenFileDialog{Title="Select a receipt to test",Filter="Receipt files (*.bin)|*.bin|All files (*.*)|*.*",InitialDirectory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"GFW8LicenseGrabber","Games"),CheckFileExists=true,Multiselect=false}){if(picker.ShowDialog(this)==DialogResult.OK)Start("single",picker.FileName);}
 }
 void Start(string mode,string receiptPath=null){
  if(worker!=null)return;
  try{
   appMutex=new Mutex(false,"Local\\GFW8LicenseGrabber-"+WindowsIdentity.GetCurrent().User.Value);try{appLock=appMutex.WaitOne(0);}catch(AbandonedMutexException){appLock=true;}
   if(!appLock){appMutex.Dispose();appMutex=null;Log("Close the main app or CLI before starting a token batch. Their active session is protected.",Color.Yellow);return;}
   string runs=Path.Combine(Lab.Home,"Runs");Lab.PrivateDirectory(runs);job=Path.Combine(runs,DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,8));Lab.PrivateDirectory(job);lastJob=job;
   if(mode=="single")File.WriteAllText(Path.Combine(job,"single-receipt-private.json"),Lab.Json.Serialize(new{path=receiptPath}));
   var psi=new ProcessStartInfo{FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe"),Arguments="-NoProfile -ExecutionPolicy Bypass -File \""+Path.Combine(runtime,"Runner.ps1")+"\" -Job \""+job+"\" -Mode "+mode+(prompts.Checked?" -AllowPrompts":""),UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=runtime,RedirectStandardOutput=true,RedirectStandardError=true};
   workerLog=TextWriter.Synchronized(new StreamWriter(Path.Combine(job,"worker-private.log"),false){AutoFlush=true});
   worker=new Process{StartInfo=psi};worker.OutputDataReceived+=delegate(object s,DataReceivedEventArgs e){if(e.Data!=null)workerLog.WriteLine(e.Data);};worker.ErrorDataReceived+=delegate(object s,DataReceivedEventArgs e){if(e.Data!=null)workerLog.WriteLine(e.Data);};worker.Start();worker.BeginOutputReadLine();worker.BeginErrorReadLine();
   complete=false;stopRequested=false;eventLines=0;rows.Clear();table.Rows.Clear();SetRunningControls(true);stage.Text="Starting batch…";status.Text="Running";Log(mode=="pull"?"Started receipt pull followed by token tests.":mode=="single"?"Started one receipt token test.":"Started tests using saved receipts.",Color.Cyan);
  }catch(Exception e){if(worker!=null){worker.Dispose();worker=null;}if(workerLog!=null){workerLog.Dispose();workerLog=null;}ReleaseMainLock();SetRunningControls(false);Log("Could not start the batch ("+e.GetType().Name+").",Color.OrangeRed);}
 }
 void ReleaseMainLock(){if(appMutex!=null){if(appLock)appMutex.ReleaseMutex();appMutex.Dispose();appMutex=null;appLock=false;}}
 void SetRunningControls(bool running){pull.Enabled=saved.Enabled=single.Enabled=prompts.Enabled=!running;stop.Enabled=running&&!stopRequested;}
 void Cancel(){if(worker==null||stopRequested)return;try{File.WriteAllText(Path.Combine(job,"cancel.flag"),"");stopRequested=true;stop.Enabled=false;status.Text="Stop requested";stage.Text="Stopping after the current request and helper cleanup…";Log("Stop requested. Waiting for the current request and helper cleanup.",Color.Yellow);}catch{Log("Could not write the stop request. The worker is still running.",Color.Yellow);}}
 void OpenReports(){string path=String.IsNullOrEmpty(lastJob)?Path.Combine(Lab.Home,"Runs"):lastJob;Lab.PrivateDirectory(path);Process.Start(new ProcessStartInfo("explorer.exe","\""+path+"\""){UseShellExecute=true});}
 void CopyFailures(){string path=Path.Combine(lastJob,"token-failures.csv");if(!String.IsNullOrEmpty(lastJob)&&File.Exists(path)){Clipboard.SetText(File.ReadAllText(path));Log("Copied the sanitized token failure report.",Color.LightGreen);}else Log("No token failure report is available yet.",Color.Yellow);}
 void Poll(){
  if(worker==null)return;
  ReadEvents();
  if(worker.HasExited){worker.WaitForExit();ReadEvents();int code=worker.ExitCode;worker.Dispose();worker=null;if(workerLog!=null){workerLog.Dispose();workerLog=null;}ReleaseMainLock();SetRunningControls(false);if(!complete){stage.Text="Worker stopped unexpectedly. Check the private worker log before retrying.";status.Text="Worker exit "+code;Log(stage.Text,Color.OrangeRed);}progress.Value=0;}
 }
 void ReadEvents(){
  string path=Path.Combine(job,"events.jsonl");if(!File.Exists(path))return;
  try{string text;using(var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var r=new StreamReader(f))text=r.ReadToEnd();var lines=text.Split('\n');int count=lines.Length-1;while(eventLines<count){string line=lines[eventLines++].Trim();if(line.Length==0)continue;try{HandleEvent(JsonMap(line));}catch{Log("A diagnostic event could not be read.",Color.Yellow);}}}catch(IOException){}
 }
 static Dictionary<string,object> JsonMap(string text){return (Dictionary<string,object>)Lab.Json.DeserializeObject(text);}
 void HandleEvent(Dictionary<string,object> e){
  string kind=TextOf(e,"kind");
  if(kind=="log"){Log(TextOf(e,"text"),TextOf(e,"level")=="error"?Color.FromArgb(255,120,120):Color.Gainsboro);}
  else if(kind=="stage"){if(!stopRequested)stage.Text=TextOf(e,"text");}
  else if(kind=="progress"){int total=Convert.ToInt32(e["total"]),done=Convert.ToInt32(e["done"]);progress.Maximum=Math.Max(1,total);progress.Value=Math.Min(progress.Maximum,Math.Max(0,done));if(!stopRequested)stage.Text=TextOf(e,"phase")+"  "+done+" / "+total+"  ·  "+TextOf(e,"game");}
  else if(kind=="result"){
   var row=(Dictionary<string,object>)e["row"];int id=Convert.ToInt32(row["gameId"]);DataGridViewRow grid;
   if(!rows.TryGetValue(id,out grid)){int index=table.Rows.Add();grid=table.Rows[index];rows[id]=grid;}grid.SetValues(TextOf(row,"game"),TextOf(row,"receipt"),TextOf(row,"licenseType"),TextOf(row,"token"),TextOf(row,"code"),TextOf(row,"cleanup"));grid.Tag=row;
   grid.Cells["token"].Style.ForeColor=TextOf(row,"token")=="Valid token"?Color.LightGreen:TextOf(row,"token")=="Not attempted"||TextOf(row,"token")=="No fresh receipt"?Color.Silver:Color.FromArgb(255,165,100);
   if(TextOf(row,"cleanup")=="UNCONFIRMED")grid.Cells["cleanup"].Style.ForeColor=Color.Red;
  }else if(kind=="complete"){
   complete=true;stop.Enabled=false;var s=(Dictionary<string,object>)e["summary"];string reason=TextOf(s,"stoppedReason");bool cancelled=Convert.ToBoolean(s["cancelled"]);
   status.Text=TextOf(s,"validTokens")+" valid tokens  ·  "+TextOf(s,"tokenFailures")+" token failures / blocks";
   stage.Text=reason.Length>0?"Stopped: "+reason:cancelled?"Stopped after cleanup.":"Batch complete.";Log(stage.Text,reason.Length>0?Color.Yellow:Color.LightGreen);Log(status.Text+". Reports saved locally.",Color.Cyan);
  }
 }
 internal void SelfTest(){
  if(!prompts.Checked||stop.Enabled||stop.Text!="Stop Current Process")throw new Exception("Idle controls or sign-in default fixture failed.");
  HandleEvent(JsonMap("{\"kind\":\"result\",\"row\":{\"gameId\":1,\"game\":\"Fixture\",\"receipt\":\"Fresh\",\"licenseType\":\"Trial\",\"token\":\"Xbox rejected\",\"code\":\"0x8015DA87\",\"cleanup\":\"Complete\"}}"));
  HandleEvent(JsonMap("{\"kind\":\"progress\",\"phase\":\"Tokens\",\"done\":1,\"total\":1,\"game\":\"Fixture\"}"));
  HandleEvent(JsonMap("{\"kind\":\"complete\",\"summary\":{\"validTokens\":0,\"tokenFailures\":1,\"cancelled\":false,\"stoppedReason\":\"\"}}"));
  if(table.Rows.Count!=1||Convert.ToString(table.Rows[0].Cells["licenseType"].Value)!="Trial"||single.Text!="Test a single receipt"||saved.Text!="Test all saved receipts"||!complete||!stage.Text.Contains("complete"))throw new Exception("UI event fixture failed.");
  string testRoot=Path.Combine(Path.GetTempPath(),"GFW8TokenLab-UiFixture-"+Guid.NewGuid().ToString("N"));
  try{
   Lab.PrivateDirectory(testRoot);job=testRoot;worker=new Process();complete=false;stopRequested=false;SetRunningControls(true);
   if(!stop.Enabled||pull.Enabled||saved.Enabled||single.Enabled||prompts.Enabled)throw new Exception("Running controls fixture failed.");
   Cancel();
   if(!File.Exists(Path.Combine(job,"cancel.flag"))||!stopRequested||stop.Enabled||status.Text!="Stop requested")throw new Exception("Stop request fixture failed.");
   int logLength=activity.TextLength;Cancel();if(activity.TextLength!=logLength)throw new Exception("Duplicate stop request fixture failed.");
   HandleEvent(JsonMap("{\"kind\":\"stage\",\"text\":\"Late worker stage\"}"));
   HandleEvent(JsonMap("{\"kind\":\"progress\",\"phase\":\"Tokens\",\"done\":1,\"total\":2,\"game\":\"Fixture\"}"));
   if(!stage.Text.StartsWith("Stopping after"))throw new Exception("Worker event hid pending stop fixture failed.");
   HandleEvent(JsonMap("{\"kind\":\"complete\",\"summary\":{\"validTokens\":0,\"tokenFailures\":1,\"cancelled\":true,\"stoppedReason\":\"\"}}"));
   worker.Dispose();worker=null;SetRunningControls(false);
   if(stop.Enabled||!pull.Enabled||!saved.Enabled||!single.Enabled||!prompts.Enabled||!prompts.Checked||stage.Text!="Stopped after cleanup.")throw new Exception("Stopped controls fixture failed.");
  }finally{
   if(worker!=null){worker.Dispose();worker=null;}job="";
   string full=Path.GetFullPath(testRoot),temp=Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\')+"\\";
   if(full.StartsWith(temp,StringComparison.OrdinalIgnoreCase)&&Path.GetFileName(full).StartsWith("GFW8TokenLab-UiFixture-",StringComparison.Ordinal))Directory.Delete(full,true);
  }
 }
 protected override void Dispose(bool disposing){if(disposing){if(timer!=null)timer.Dispose();ReleaseMainLock();}base.Dispose(disposing);}
}

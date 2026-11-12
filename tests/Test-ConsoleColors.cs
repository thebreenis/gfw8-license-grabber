// Regression for Windows Terminal background-colour erase/scroll bleed.
using System;
using System.IO;
using System.Reflection;
using System.Text;

class ConsoleColorTests {
 sealed class Capture : TextWriter {
  public override Encoding Encoding { get { return Encoding.UTF8; } }
  public int Lines, TileWrites, BadNewlines, BadNormalWrites;
  public ConsoleColor ExpectedTile;
  public bool InTile;
  public override void Write(string value) {
   if (InTile) { if (Console.BackgroundColor != ExpectedTile) BadNormalWrites++; TileWrites++; }
   else if (Console.BackgroundColor != ConsoleColor.Black) BadNormalWrites++;
  }
  public override void WriteLine() { Lines++; if (Console.BackgroundColor != ConsoleColor.Black) BadNewlines++; }
  public override void WriteLine(string value) { Write(value); WriteLine(); }
 }
 static int Main(string[] args) {
  TextWriter original = Console.Out; TextReader input = Console.In;
  ConsoleColor foreground = Console.ForegroundColor, background = Console.BackgroundColor;
  try {
   Type program = Assembly.LoadFile(Path.GetFullPath(args[0])).GetType("Program");
   const BindingFlags flags = BindingFlags.Static | BindingFlags.NonPublic;
   program.GetField("colour", flags).SetValue(null, true);
   MethodInfo tile = program.GetMethod("Tile", flags), line = program.GetMethod("Line", flags), prompt = program.GetMethod("Prompt", flags);
   var capture = new Capture(); Console.SetOut(capture);
   foreach (var colour in new[] { ConsoleColor.DarkCyan, ConsoleColor.DarkMagenta, ConsoleColor.DarkGreen }) {
    capture.ExpectedTile = colour; capture.InTile = true;
    tile.Invoke(null, new object[] { "SECTION", colour }); capture.InTile = false;
    Console.BackgroundColor = colour;
    line.Invoke(null, new object[] { "Menu action", ConsoleColor.White });
    Console.BackgroundColor = colour; Console.SetIn(new StringReader("1\n"));
    if ((string)prompt.Invoke(null, new object[] { "Choose:" }) != "1") throw new Exception("Prompt input changed.");
   }
   if (capture.TileWrites != 3 || capture.Lines != 6 || capture.BadNewlines != 0 || capture.BadNormalWrites != 0)
    throw new Exception(String.Format("Colour regression failed: tileWrites={0}, lines={1}, badNewlines={2}, badWrites={3}. Run in an attached console.", capture.TileWrites, capture.Lines, capture.BadNewlines, capture.BadNormalWrites));
   Console.SetOut(original);
   Console.WriteLine("PASS: all3 tile colours reset before newline; normal text and prompts reset inherited backgrounds.");
   return 0;
  } catch (Exception e) { Console.SetOut(original); Console.WriteLine(e.Message); return 1; }
  finally { Console.SetOut(original); Console.SetIn(input); Console.ForegroundColor = foreground; Console.BackgroundColor = background; }
 }
}

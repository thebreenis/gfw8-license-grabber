// Same Metro spacing and colors as the main app; glyphs are drawn to stay centered at any DPI.
using System;using System.Drawing;using System.Drawing.Drawing2D;using System.Runtime.InteropServices;using System.Windows.Forms;
namespace Gfw8Sharing {
 static class MetroChrome {
  [DllImport("user32.dll")]static extern bool ReleaseCapture();[DllImport("user32.dll")]static extern IntPtr SendMessage(IntPtr h,int m,IntPtr w,IntPtr l);
  public static Panel Create(Form form,string text,Action maximize){
   var chrome=new Panel{Dock=DockStyle.Top,Width=form.ClientSize.Width,Height=60,BackColor=form.BackColor};
   var title=new Label{Text=text,Font=new Font("Segoe UI Light",22),Location=new Point(20,5),Size=new Size(400,50),ForeColor=Color.White};chrome.Controls.Add(title);
   var controls=new TableLayoutPanel{Size=new Size(132,30),Location=new Point(form.ClientSize.Width-152,8),Anchor=AnchorStyles.Top|AnchorStyles.Right,ColumnCount=3,RowCount=1,Margin=new Padding(0)};for(int n=0;n<3;n++)controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.333f));
   controls.Controls.Add(Button(form,0,"Minimize",()=>form.WindowState=FormWindowState.Minimized),0,0);controls.Controls.Add(Button(form,1,"Maximize or restore",maximize),1,0);controls.Controls.Add(Button(form,2,"Close",()=>form.Close()),2,0);chrome.Controls.Add(controls);
   MouseEventHandler drag=delegate(object s,MouseEventArgs e){if(e.Button==MouseButtons.Left){ReleaseCapture();SendMessage(form.Handle,0xA1,new IntPtr(2),IntPtr.Zero);}};chrome.MouseDown+=drag;title.MouseDown+=drag;title.DoubleClick+=delegate{maximize();};return chrome;
  }
  static Button Button(Form f,int glyph,string name,Action action){var b=new GlyphButton(glyph){AccessibleName=name,Dock=DockStyle.Fill,Margin=new Padding(0),Padding=new Padding(0),FlatStyle=FlatStyle.Flat,ForeColor=Color.White,BackColor=glyph==2?Color.FromArgb(185,35,41):f.BackColor,TabStop=false};b.FlatAppearance.BorderSize=0;b.FlatAppearance.MouseOverBackColor=Color.FromArgb(75,53,83);b.FlatAppearance.MouseDownBackColor=Color.FromArgb(105,87,113);b.Click+=delegate{action();};return b;}
  sealed class GlyphButton:Button {
   readonly int glyph;public GlyphButton(int g){glyph=g;}
   protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);float x=ClientSize.Width/2f,y=ClientSize.Height/2f,h=ClientSize.Height*.14f;e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var p=new Pen(Color.White,glyph==2?1.8f:1.2f)){if(glyph==0)e.Graphics.DrawLine(p,x-h*1.5f,y,x+h*1.5f,y);else if(glyph==1)e.Graphics.DrawRectangle(p,x-h*.8f,y-h*.8f,h*1.6f,h*1.6f);else{e.Graphics.DrawLine(p,x-h,y-h,x+h,y+h);e.Graphics.DrawLine(p,x-h,y+h,x+h,y-h);}}}
  }
 }
}

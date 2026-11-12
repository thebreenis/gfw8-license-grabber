using System;using System.Drawing;using System.Runtime.InteropServices;using System.Windows.Forms;
namespace Gfw8Sharing {
 static class MetroChrome {
  [DllImport("user32.dll")]static extern bool ReleaseCapture();[DllImport("user32.dll")]static extern IntPtr SendMessage(IntPtr h,int m,IntPtr w,IntPtr l);
  public static Panel Create(Form form,string text,Action maximize){
   var chrome=new Panel{Dock=DockStyle.Top,Width=form.ClientSize.Width,Height=60,BackColor=form.BackColor};
   var title=new Label{Text=text,Font=new Font("Segoe UI Light",22),AutoSize=false,Location=new Point(20,5),Size=new Size(400,50),ForeColor=Color.White};chrome.Controls.Add(title);
   var controls=new TableLayoutPanel{Size=new Size(132,30),Location=new Point(form.ClientSize.Width-152,8),Anchor=AnchorStyles.Top|AnchorStyles.Right,ColumnCount=3,RowCount=1,Margin=new Padding(0)};for(int n=0;n<3;n++)controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.333f));
   controls.Controls.Add(Button(form,"—","Minimize",()=>form.WindowState=FormWindowState.Minimized,false),0,0);controls.Controls.Add(Button(form,"□","Maximize or restore",maximize,false),1,0);controls.Controls.Add(Button(form,"×","Close",()=>form.Close(),true),2,0);chrome.Controls.Add(controls);
   MouseEventHandler drag=delegate(object s,MouseEventArgs e){if(e.Button==MouseButtons.Left){ReleaseCapture();SendMessage(form.Handle,0xA1,new IntPtr(2),IntPtr.Zero);}};chrome.MouseDown+=drag;title.MouseDown+=drag;title.DoubleClick+=delegate{maximize();};return chrome;
  }
  static Button Button(Form form,string text,string name,Action action,bool close){var b=new Button{Text=text,AccessibleName=name,Dock=DockStyle.Fill,Margin=new Padding(0),Padding=new Padding(0),FlatStyle=FlatStyle.Flat,ForeColor=Color.White,BackColor=close?Color.FromArgb(185,35,41):form.BackColor,Font=new Font("Segoe UI",close?23:14),TabStop=false};b.FlatAppearance.BorderSize=0;b.FlatAppearance.MouseOverBackColor=Color.FromArgb(75,53,83);b.FlatAppearance.MouseDownBackColor=Color.FromArgb(105,87,113);b.Click+=delegate{action();};return b;}
 }
}

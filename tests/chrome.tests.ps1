param([string]$ExePath = (Join-Path $PSScriptRoot '..\dist\Skiptify.exe'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Drawing;
public static class ChromeRegression {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
    static void Click(Control button, int downMessage = 0x201) {
        var point = new Point(button.Width / 2, button.Height / 2);
        Cursor.Position = button.PointToScreen(point);
        IntPtr coordinates = new IntPtr((point.Y << 16) | point.X);
        SendMessage(button.Handle, downMessage, new IntPtr(1), coordinates);
        SendMessage(button.Handle, 0x202, IntPtr.Zero, coordinates);
        Application.DoEvents();
    }
    public static void Run(string path) {
        var assembly = Assembly.LoadFrom(path);
        var type = assembly.GetType("SkiptifyDesktop.MainForm", true);
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        Point originalCursor = Cursor.Position;
        using (var form = (Form)Activator.CreateInstance(type, true)) {
            try {
                form.Show(); Application.DoEvents();
                int style = GetWindowLong(form.Handle, -16);
                if ((style & 0x000A0000) != 0x000A0000)
                    throw new Exception("Native taskbar minimization styles are missing.");
                if ((style & 0x00C00000) != 0)
                    throw new Exception("Native caption unexpectedly replaced custom chrome.");
                SendMessage(form.Handle, 0x112, new IntPtr(0xF020), IntPtr.Zero);
                Application.DoEvents();
                if (form.WindowState != FormWindowState.Minimized)
                    throw new Exception("Native minimize command failed.");
                SendMessage(form.Handle, 0x112, new IntPtr(0xF120), IntPtr.Zero);
                Application.DoEvents();
                if (form.WindowState != FormWindowState.Normal)
                    throw new Exception("Native restore command failed.");
                var maximize = (Control)type.GetField("maximizeButton", flags).GetValue(form);
                var minimize = (Control)type.GetField("minimizeButton", flags).GetValue(form);
                var close = (Control)type.GetField("closeButton", flags).GetValue(form);
                int clicks = 0;
                maximize.Click += delegate { clicks++; };
                Click(maximize);
                if (clicks != 1 || form.WindowState != FormWindowState.Maximized)
                    throw new Exception("One maximize click: events=" + clicks + ", state=" + form.WindowState);
                Click(maximize, 0x203); // Windows' second press in a double-click sequence.
                if (clicks != 2 || form.WindowState != FormWindowState.Normal)
                    throw new Exception("Restore on rapid second click failed: events=" + clicks + ", state=" + form.WindowState);
                int minClicks = 0;
                minimize.Click += delegate { minClicks++; };
                Click(minimize);
                if (minClicks != 1 || form.WindowState != FormWindowState.Minimized)
                    throw new Exception("One minimize click failed: events=" + minClicks + ", state=" + form.WindowState);
                form.WindowState = FormWindowState.Normal; Application.DoEvents();
                int closeClicks = 0;
                close.Click += delegate { closeClicks++; };
                Click(close);
                if (closeClicks != 1 || !form.IsDisposed)
                    throw new Exception("One close click failed: events=" + closeClicks);
                Console.WriteLine("PASS: native minimize/restore, borderless styles, maximize, rapid restore, minimize, close; one event per click.");
            } finally {
                if (!form.IsDisposed) form.Close();
                Cursor.Position = originalCursor;
            }
        }
    }
}
'@
[ChromeRegression]::Run((Resolve-Path -LiteralPath $ExePath).Path)

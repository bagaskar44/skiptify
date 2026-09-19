using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Skiptify")]
[assembly: AssemblyDescription("Lightweight Spotify monitoring helper")]
[assembly: AssemblyProduct("Skiptify")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace SkiptifyDesktop
{
    internal static class Program
    {
        private const string UiMutexName = "Local\\Skiptify.Desktop.1.0";

        [STAThread]
        private static void Main()
        {
            bool createdNew;
            using (var mutex = new Mutex(true, UiMutexName, out createdNew))
            {
                if (!createdNew)
                {
                    MainForm.ActivateExistingWindow();
                    return;
                }

                MainForm.InitializeDpi();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
            }
        }
    }

    [DataContract]
    internal sealed class WorkerMessage
    {
        [DataMember(Name = "status")]
        public string Status { get; set; }

        [DataMember(Name = "message")]
        public string Message { get; set; }

        [DataMember(Name = "recoveryId")]
        public string RecoveryId { get; set; }

        [DataMember(Name = "eventName")]
        public string EventName { get; set; }

        [DataMember(Name = "processId")]
        public int ProcessId { get; set; }

        [DataMember(Name = "windowHandle")]
        public long WindowHandle { get; set; }
    }

    internal sealed class MainForm : Form
    {
        private const string StopEventName = "Local\\Skiptify.Desktop.Stop.1.0";
        private const int WorkerStopTimeoutMs = 15000;
        private const int OverlayCaptureMaxMs = 500;
        private const int OverlayMaxMs = 8000;
        private const int OverlayRenderDelayMs = 300;
        private const int OverlayPostPlayMinimumMs = 1500;
        private const int HandoffPollIntervalMs = 100;
        private const int HandoffReadyStableChecks = 3;
        private const long MaxBitmapBytes = 64L * 1024L * 1024L;

        private readonly SkiptifyToggle toggle;
        private string statusText = "Off";
        private string hintText = "Tekan On untuk mulai.";
        private Color statusColor = Color.FromArgb(178, 204, 211);
        private Bitmap logoBitmap;
        private Bitmap logoWatermarkBitmap;
        private Icon logoIcon;
        private ChromeButton minimizeButton;
        private ChromeButton maximizeButton;
        private ChromeButton closeButton;
        private EventWaitHandle stopEvent;
        private Process worker;
        private System.Threading.Timer stopTimer;
        private System.Windows.Forms.Timer overlayWatchTimer;
        private System.Windows.Forms.Timer handoffTimer;
        private Task<OverlayCaptureResult> overlayCaptureTask;
        private OverlayContext overlayContext;
        private OverlayForm overlay;
        private WorkerMessage pendingHandoff;
        private DateTime handoffRequestedUtc;
        private int handoffReadyStableChecks;
        private string handoffLastTitle;
        private readonly HashSet<string> closedRecoveryIds = new HashSet<string>(StringComparer.Ordinal);
        private readonly Queue<string> closedRecoveryOrder = new Queue<string>();
        private int overlayGeneration;
        private bool transition;
        private bool closing;
        private bool allowClose;
        private bool stopRequested;
        private string lastStatus = "Off";

        public MainForm()
        {
            Text = "Skiptify";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(760, 520);
            MinimumSize = new Size(600, 420);
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Color.FromArgb(2, 8, 12);
            DoubleBuffered = true;
            SetStyle(ControlStyles.ResizeRedraw, true);
            Icon = SystemIcons.Application;
            LoadLogos();

            toggle = new SkiptifyToggle
            {
                Text = "OFF",
                Size = new Size(84, 224),
                TabIndex = 0,
                AccessibleName = "Aktifkan pemantauan Skiptify"
            };
            toggle.Click += Toggle_Click;

            minimizeButton = new ChromeButton(ChromeButtonKind.Minimize)
            {
                AccessibleName = "Minimalkan Skiptify",
                TabIndex = 1
            };
            maximizeButton = new ChromeButton(ChromeButtonKind.Maximize)
            {
                AccessibleName = "Maksimalkan Skiptify",
                TabIndex = 2
            };
            closeButton = new ChromeButton(ChromeButtonKind.Close)
            {
                AccessibleName = "Tutup Skiptify",
                TabIndex = 3
            };
            minimizeButton.Click += delegate { WindowState = FormWindowState.Minimized; };
            maximizeButton.Click += delegate
            {
                WindowState = WindowState == FormWindowState.Maximized
                    ? FormWindowState.Normal
                    : FormWindowState.Maximized;
            };
            closeButton.Click += delegate { Close(); };

            Controls.Add(toggle);
            Controls.Add(minimizeButton);
            Controls.Add(maximizeButton);
            Controls.Add(closeButton);
            AcceptButton = null;
            MouseDown += MainForm_MouseDown;
            MouseDoubleClick += MainForm_MouseDoubleClick;
            FormClosing += MainForm_FormClosing;
            SetStatus("Off", "Tekan On untuk mulai.");
            LayoutChromeButtons();
            LayoutToggle();
            UpdateWindowRegion();
            Shown += MainForm_Shown;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams parameters = base.CreateParams;
                // Keep the custom borderless chrome, but advertise native
                // minimization to Explorer so taskbar clicks toggle the window.
                const int WsMinimizeBox = 0x00020000;
                const int WsSysMenu = 0x00080000;
                parameters.Style |= WsMinimizeBox | WsSysMenu;
                return parameters;
            }
        }

        private void LoadLogos()
        {
            try
            {
                using (Stream stream = Assembly.GetExecutingAssembly()
                    .GetManifestResourceStream("SkiptifyDesktop.SkiptifyLogo"))
                {
                    if (stream == null) return;
                    using (var source = new Bitmap(stream))
                    {
                        logoBitmap = CreateCircularLogo(source, 64);
                        logoWatermarkBitmap = CreateCircularLogo(source, 440);
                    }
                }
                logoIcon = CreateIcon(logoBitmap);
                if (logoIcon != null) Icon = logoIcon;
            }
            catch
            {
                DisposeLogoAssets();
            }
        }

        private static Bitmap CreateCircularLogo(Bitmap source, int size)
        {
            var result = new Bitmap(size, size, PixelFormat.Format32bppPArgb);
            using (var graphics = Graphics.FromImage(result))
            using (var path = new GraphicsPath())
            {
                graphics.Clear(Color.Transparent);
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                path.AddEllipse(0, 0, size - 1, size - 1);
                graphics.SetClip(path);
                graphics.DrawImage(source, new Rectangle(0, 0, size, size),
                    0, 0, source.Width, source.Height, GraphicsUnit.Pixel);
            }
            return result;
        }

        private static Icon CreateIcon(Bitmap bitmap)
        {
            IntPtr iconHandle = IntPtr.Zero;
            try
            {
                iconHandle = bitmap.GetHicon();
                using (var temporary = Icon.FromHandle(iconHandle))
                {
                    return (Icon)temporary.Clone();
                }
            }
            catch
            {
                return null;
            }
            finally
            {
                if (iconHandle != IntPtr.Zero)
                {
                    try { NativeMethods.DestroyIcon(iconHandle); } catch { }
                }
            }
        }

        private void DisposeLogoAssets()
        {
            if (logoBitmap != null)
            {
                logoBitmap.Dispose();
                logoBitmap = null;
            }
            if (logoWatermarkBitmap != null)
            {
                logoWatermarkBitmap.Dispose();
                logoWatermarkBitmap = null;
            }
            if (logoIcon != null)
            {
                logoIcon.Dispose();
                logoIcon = null;
            }
        }

        private float UiScale
        {
            get
            {
                if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return 1f;
                // The design is intentionally capped at 100%. Without this
                // cap a maximized borderless window would enlarge every
                // control and make the compact utility look distorted.
                return Math.Max(0.78f, Math.Min(1f,
                    Math.Min(ClientSize.Width / 760f, ClientSize.Height / 520f)));
            }
        }

        private float ContentOffsetX
        {
            get { return Math.Max(0f, (ClientSize.Width - (760f * UiScale)) / 2f); }
        }

        private float ContentOffsetY
        {
            get { return Math.Max(0f, (ClientSize.Height - (520f * UiScale)) / 2f); }
        }

        private int TitleBarHeight
        {
            // Keep the custom chrome close to the height of a standard compact
            // Windows title bar. The content below the bar keeps its own layout.
            get { return Math.Max(32, (int)(34f * UiScale)); }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            LayoutChromeButtons();
            LayoutToggle();
            UpdateWindowRegion();
            Invalidate();
        }

        private void LayoutChromeButtons()
        {
            if (minimizeButton == null || maximizeButton == null || closeButton == null) return;
            float scale = UiScale;
            int width = Math.Max(32, (int)(36f * scale));
            int height = Math.Min(TitleBarHeight, Math.Max(30, (int)(32f * scale)));
            int top = (TitleBarHeight - height) / 2;
            int right = ClientSize.Width - Math.Max(6, (int)(8f * scale));
            closeButton.Bounds = new Rectangle(right - width, top, width, height);
            maximizeButton.Bounds = new Rectangle(right - (width * 2), top, width, height);
            minimizeButton.Bounds = new Rectangle(right - (width * 3), top, width, height);
            maximizeButton.IsMaximized = WindowState == FormWindowState.Maximized;
        }

        private void LayoutToggle()
        {
            if (toggle == null) return;
            float scale = UiScale;
            int width = (int)(84f * scale);
            int height = (int)(224f * scale);
            toggle.Bounds = new Rectangle((ClientSize.Width / 4) - width / 2,
                TitleBarHeight + (ClientSize.Height - TitleBarHeight - height) / 2, width, height);
        }

        private void UpdateWindowRegion()
        {
            Region previous = Region;
            if (WindowState == FormWindowState.Maximized)
            {
                Region = null;
                if (previous != null) previous.Dispose();
                return;
            }
            if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
            float radius = Math.Max(14f, 20f * UiScale);
            using (var path = CreateRoundedPath(new Rectangle(0, 0, ClientSize.Width - 1, ClientSize.Height - 1), radius))
            {
                Region = new Region(path);
                if (previous != null) previous.Dispose();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;

            float scale = UiScale;
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            using (var background = new LinearGradientBrush(new Point(0, 0),
                new Point(width, height), Color.FromArgb(2, 8, 12), Color.FromArgb(0, 38, 28)))
            {
                graphics.FillRectangle(background, ClientRectangle);
            }

            using (var leftGlow = new SolidBrush(Color.FromArgb(14, 0, 122, 84)))
            using (var rightGlow = new SolidBrush(Color.FromArgb(22, 0, 150, 96)))
            {
                graphics.FillEllipse(leftGlow, (int)(-170f * scale), (int)(265f * scale),
                    (int)(470f * scale), (int)(330f * scale));
                graphics.FillEllipse(rightGlow, (int)(width - 330f * scale), (int)(-80f * scale),
                    (int)(430f * scale), (int)(430f * scale));
            }

            using (var topBar = new LinearGradientBrush(new Point(0, 0), new Point(width, 0),
                Color.FromArgb(4, 15, 20), Color.FromArgb(1, 60, 40)))
            {
                graphics.FillRectangle(topBar, new Rectangle(0, 0, width, TitleBarHeight));
            }

            DrawWatermark(graphics, scale, width, height);
            DrawHeader(graphics, scale);
            DrawMainCopy(graphics, scale, width, height);
            DrawStatus(graphics, scale, width, height);

            if (WindowState != FormWindowState.Maximized)
            {
                using (var border = new Pen(Color.FromArgb(45, 88, 82), Math.Max(1f, 2f * scale)))
                using (var path = CreateRoundedPath(new Rectangle(1, 1, width - 3, height - 3), 20f * scale))
                {
                    graphics.DrawPath(border, path);
                }
            }
        }

        private void DrawHeader(Graphics graphics, float scale)
        {
            int logoSize = Math.Max(20, (int)(22f * scale));
            int logoX = Math.Max(14, (int)(18f * scale));
            int logoY = (TitleBarHeight - logoSize) / 2;
            if (logoBitmap != null)
            {
                graphics.DrawImage(logoBitmap, new Rectangle(logoX, logoY, logoSize, logoSize));
            }
        }

        private void DrawMainCopy(Graphics graphics, float scale, int width, int height)
        {
            float centerY = TitleBarHeight + (height - TitleBarHeight) / 2f;
            using (var taglineFont = new Font("Segoe Print", Math.Max(15f, 20f * scale), FontStyle.Bold | FontStyle.Italic))
            using (var taglineBrush = new SolidBrush(Color.FromArgb(0, 231, 144)))
            {
                using (var format = new StringFormat
                {
                    Alignment = StringAlignment.Center,
                    LineAlignment = StringAlignment.Center
                })
                {
                float left = width / 2f + 12f * scale;
                float copyWidth = width / 2f - 24f * scale;
                graphics.DrawString("Skip the ads.", taglineFont, taglineBrush,
                    new RectangleF(left, centerY + 55f * scale, copyWidth, 52f * scale), format);
                graphics.DrawString("Keep the music.", taglineFont, taglineBrush,
                    new RectangleF(left, centerY + 103f * scale, copyWidth, 52f * scale), format);
                }
            }

        }

        private void DrawStatus(Graphics graphics, float scale, int width, int height)
        {
            if (lastStatus != "Gagal" && lastStatus != "Konflik")
            {
                return;
            }

            using (var statusFont = new Font("Segoe UI", Math.Max(12f, 16f * scale), FontStyle.Bold))
            using (var statusBrush = new SolidBrush(statusColor))
            using (var hintFont = new Font("Segoe UI", Math.Max(10f, 13f * scale), FontStyle.Regular))
            using (var hintBrush = new SolidBrush(Color.FromArgb(163, 192, 199)))
            using (var hintFormat = new StringFormat
            {
                Trimming = StringTrimming.EllipsisCharacter,
                FormatFlags = StringFormatFlags.NoWrap
            })
            {
                graphics.DrawString(statusText, statusFont, statusBrush,
                    (int)(24f * scale), toggle.Bottom + 18f * scale);
                graphics.DrawString(hintText ?? string.Empty, hintFont, hintBrush,
                    new RectangleF(24f * scale, toggle.Bottom + 47f * scale,
                        width / 2f - 48f * scale, Math.Max(20f, 24f * scale)), hintFormat);
            }
        }

        private void DrawWatermark(Graphics graphics, float scale, int width, int height)
        {
            if (logoWatermarkBitmap == null) return;
            int watermarkSize = (int)(340f * scale);
            int x = (int)(width * 0.75f - watermarkSize / 2f);
            int y = TitleBarHeight + (height - TitleBarHeight - watermarkSize) / 2;
            using (var attributes = new ImageAttributes())
            {
                    var matrix = new ColorMatrix(new float[][]
                {
                    new float[] { 1, 0, 0, 0, 0 },
                    new float[] { 0, 1, 0, 0, 0 },
                    new float[] { 0, 0, 1, 0, 0 },
                    new float[] { 0, 0, 0, 0.10f, 0 },
                    new float[] { 0, 0, 0, 0, 0 }
                });
                attributes.SetColorMatrix(matrix, ColorMatrixFlag.Default, ColorAdjustType.Bitmap);
                graphics.DrawImage(logoWatermarkBitmap, new Rectangle(x, y, watermarkSize, watermarkSize),
                    0, 0, logoWatermarkBitmap.Width, logoWatermarkBitmap.Height,
                    GraphicsUnit.Pixel, attributes);
            }
        }

        private static GraphicsPath CreateRoundedPath(Rectangle rectangle, float radius)
        {
            var path = new GraphicsPath();
            float diameter = Math.Max(2f, radius * 2f);
            RectangleF bounds = rectangle;
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        private void MainForm_MouseDown(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left || e.Y > TitleBarHeight || IsChromeButtonAt(e.Location)) return;
            NativeMethods.ReleaseCapture();
            NativeMethods.SendMessage(Handle, NativeMethods.WmNcLButtonDown,
                new IntPtr(NativeMethods.HTCaption), IntPtr.Zero);
        }

        private void MainForm_MouseDoubleClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && e.Y <= TitleBarHeight && !IsChromeButtonAt(e.Location))
            {
                WindowState = WindowState == FormWindowState.Maximized
                    ? FormWindowState.Normal
                    : FormWindowState.Maximized;
            }
        }

        private bool IsChromeButtonAt(Point point)
        {
            return (minimizeButton != null && minimizeButton.Bounds.Contains(point))
                || (maximizeButton != null && maximizeButton.Bounds.Contains(point))
                || (closeButton != null && closeButton.Bounds.Contains(point));
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                DisposeLogoAssets();
            }
            base.Dispose(disposing);
        }

        public static void InitializeDpi()
        {
            try
            {
                NativeMethods.SetProcessDpiAwarenessContext(NativeMethods.DpiAwarenessContextPerMonitorV2);
            }
            catch
            {
                // Older Windows builds simply keep the process' default DPI mode.
            }
        }

        public static void ActivateExistingWindow()
        {
            IntPtr handle = FindSkiptifyWindow();
            if (handle != IntPtr.Zero)
            {
                NativeMethods.ShowWindow(handle, NativeMethods.SwRestore);
                NativeMethods.SetForegroundWindow(handle);
            }
        }

        private static IntPtr FindSkiptifyWindow()
        {
            IntPtr found = IntPtr.Zero;
            NativeMethods.EnumWindows(delegate(IntPtr handle, IntPtr state)
            {
                var title = new StringBuilder(128);
                NativeMethods.GetWindowText(handle, title, title.Capacity);
                if (string.Equals(title.ToString(), "Skiptify", StringComparison.Ordinal))
                {
                    found = handle;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        private void Toggle_Click(object sender, EventArgs e)
        {
            if (transition && lastStatus != "Memulihkan")
            {
                return;
            }

            if (toggle.Checked)
            {
                StartWorker();
            }
            else
            {
                StopWorker(false);
            }
        }

        private void MainForm_Shown(object sender, EventArgs e)
        {
            // Show a useful explanation when the legacy VBS launcher owns the
            // engine. This check is one-shot and does not poll Spotify.
            if (IsEngineRunning())
            {
                SetStatus("Konflik", "Skiptify sudah berjalan dari launcher lain.");
            }
        }

        private static bool IsEngineRunning()
        {
            bool createdNew;
            using (var mutex = new Mutex(false, "Local\\Skiptify.Engine.1.0", out createdNew))
            {
                try
                {
                    if (mutex.WaitOne(0))
                    {
                        mutex.ReleaseMutex();
                        return false;
                    }
                    return true;
                }
                catch (AbandonedMutexException)
                {
                    try { mutex.ReleaseMutex(); } catch { }
                    return false;
                }
            }
        }

        private void StartWorker()
        {
            if (worker != null || transition)
            {
                return;
            }

            if (IsEngineRunning())
            {
                toggle.Checked = false;
                SetStatus("Konflik", "Skiptify sudah berjalan dari launcher lain.");
                return;
            }

            string scriptPath = Path.Combine(Application.StartupPath, "skiptify.ps1");
            if (!File.Exists(scriptPath))
            {
                toggle.Checked = false;
                SetStatus("Gagal", "skiptify.ps1 tidak ditemukan.");
                return;
            }

            try
            {
                bool createdNew;
                stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, StopEventName, out createdNew);
                stopEvent.Reset();

                string powershell = FindPowerShell();
                var info = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "
                        + Quote(scriptPath)
                        + " -HostPid " + Process.GetCurrentProcess().Id
                        + " -StopEventName " + Quote(StopEventName)
                        + " -VisibleStartup",
                    WorkingDirectory = Application.StartupPath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                worker = new Process { StartInfo = info, EnableRaisingEvents = true };
                worker.OutputDataReceived += Worker_OutputDataReceived;
                worker.ErrorDataReceived += Worker_ErrorDataReceived;
                worker.Exited += Worker_Exited;
                if (!worker.Start())
                {
                    throw new InvalidOperationException("PowerShell tidak dapat dijalankan.");
                }

                stopRequested = false;
                transition = true;
                toggle.Enabled = false;
                toggle.Text = "...";
                SetStatus("Memulai", "Menyiapkan pemantauan Spotify.");
                worker.BeginOutputReadLine();
                worker.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                CleanupWorker();
                toggle.Checked = false;
                SetStatus("Gagal", ShortMessage(ex.Message));
            }
        }

        private void StopWorker(bool forClose)
        {
            stopRequested = true;
            HideOverlay();

            if (worker == null)
            {
                toggle.Checked = false;
                toggle.Enabled = true;
                SetStatus("Off", "Pemantauan berhenti.");
                return;
            }

            if (transition && lastStatus == "Menghentikan")
            {
                return;
            }

            closing = closing || forClose;
            transition = true;
            toggle.Checked = false;
            toggle.Enabled = false;
            toggle.Text = "...";
            SetStatus("Menghentikan", "Menghentikan pemantauan.");

            try
            {
                if (stopEvent != null)
                {
                    stopEvent.Set();
                }
            }
            catch
            {
                // The worker exit handler still performs cleanup if the event is gone.
            }

            if (stopTimer == null)
            {
                stopTimer = new System.Threading.Timer(ForceStopWorker, null, WorkerStopTimeoutMs, Timeout.Infinite);
            }
        }

        private void ForceStopWorker(object state)
        {
            try
            {
                if (worker != null && !worker.HasExited)
                {
                    worker.Kill();
                }
            }
            catch
            {
                // The process may have exited between HasExited and Kill.
            }
        }

        private void Worker_OutputDataReceived(object sender, DataReceivedEventArgs e)
        {
            if (!string.IsNullOrWhiteSpace(e.Data))
            {
                WorkerMessage message;
                if (TryParseStatus(e.Data, out message))
                {
                    Process source = sender as Process;
                    PostToUi(delegate
                    {
                        if (source == worker) ApplyWorkerMessage(message);
                    });
                }
            }
        }

        private void Worker_ErrorDataReceived(object sender, DataReceivedEventArgs e)
        {
            // PowerShell warnings and diagnostics remain in the worker log. Do not
            // update the UI for every diagnostic line.
        }

        private void Worker_Exited(object sender, EventArgs e)
        {
            Process source = sender as Process;
            PostToUi(delegate
            {
                if (source == worker) HandleWorkerExit();
            });
        }

        private void ApplyWorkerMessage(WorkerMessage message)
        {
            if (IsDisposed || worker == null || message == null || string.IsNullOrWhiteSpace(message.Status))
            {
                return;
            }

            if (message.Status == "OverlayPrepare")
            {
                PrepareOverlay(message);
                return;
            }

            if (message.Status == "OverlayRelease")
            {
                ReleaseOverlay(message);
                return;
            }

            // A late success line from a recovery that is already stopping must
            // never turn the toggle back on.
            if (stopRequested && (message.Status == "Aktif" || message.Status == "Memulihkan"))
            {
                return;
            }

            SetStatus(message.Status, string.IsNullOrWhiteSpace(message.Message)
                ? DefaultMessage(message.Status)
                : message.Message);

            if (message.Status == "Aktif")
            {
                transition = false;
                toggle.Enabled = true;
                toggle.Checked = true;
                toggle.Text = "ON";
            }
            else if (message.Status == "Memulihkan")
            {
                // Recovery is cancellable: keep the toggle available so the
                // user can request Off while Spotify is being restarted.
                transition = true;
                toggle.Enabled = true;
                toggle.Checked = true;
                toggle.Text = "ON";
            }
            else if (message.Status == "Gagal" || message.Status == "Konflik")
            {
                transition = false;
                toggle.Enabled = true;
                toggle.Checked = false;
                toggle.Text = "OFF";
            }
        }

        private void HandleWorkerExit()
        {
            if (IsDisposed)
            {
                return;
            }

            int exitCode = -1;
            try { exitCode = worker == null ? -1 : worker.ExitCode; } catch { }
            bool wasStopping = lastStatus == "Menghentikan" || closing || stopRequested;
            HideOverlay();
            CleanupWorker();

            transition = false;
            stopRequested = false;
            toggle.Enabled = true;
            toggle.Checked = false;
            toggle.Text = "OFF";

            if (!wasStopping && exitCode != 0 && lastStatus != "Gagal" && lastStatus != "Konflik")
            {
                SetStatus("Gagal", "Worker berhenti secara tidak terduga.");
            }
            else if (lastStatus != "Gagal" && lastStatus != "Konflik")
            {
                SetStatus("Off", "Pemantauan berhenti.");
            }

            if (closing)
            {
                allowClose = true;
                BeginInvoke(new Action(Close));
            }
        }

        private void MainForm_FormClosing(object sender, FormClosingEventArgs e)
        {
            if (allowClose || worker == null)
            {
                HideOverlay();
                CleanupWorker();
                return;
            }

            e.Cancel = true;
            StopWorker(true);
        }

        private void CleanupWorker()
        {
            if (stopTimer != null)
            {
                stopTimer.Dispose();
                stopTimer = null;
            }

            HideOverlay();
            overlayGeneration++;
            overlayCaptureTask = null;

            if (worker != null)
            {
                worker.OutputDataReceived -= Worker_OutputDataReceived;
                worker.ErrorDataReceived -= Worker_ErrorDataReceived;
                worker.Exited -= Worker_Exited;
                worker.Dispose();
                worker = null;
            }

            if (stopEvent != null)
            {
                stopEvent.Dispose();
                stopEvent = null;
            }
        }

        private void PostToUi(Action action)
        {
            try
            {
                if (!IsDisposed && IsHandleCreated)
                {
                    BeginInvoke(action);
                }
            }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { }
        }

        private void SetStatus(string status, string message)
        {
            lastStatus = status;
            statusText = status ?? "Off";
            hintText = message ?? string.Empty;
            statusColor = status == "Gagal" || status == "Konflik"
                ? Color.FromArgb(255, 152, 152)
                : Color.FromArgb(178, 204, 211);
            Invalidate();
        }

        private static void WriteUiLog(string message)
        {
            try
            {
                string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Skiptify", "Logs");
                Directory.CreateDirectory(directory);
                string path = Path.Combine(directory, "desktop.log");
                string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine;
                if (File.Exists(path) && new FileInfo(path).Length + Encoding.UTF8.GetByteCount(line) > 1024L * 1024L)
                {
                    string archive = Path.Combine(directory, "desktop.1.log");
                    if (File.Exists(archive)) File.Delete(archive);
                    File.Move(path, archive);
                }
                File.AppendAllText(path, line, Encoding.UTF8);
            }
            catch
            {
                // Diagnostics must never affect the worker or UI lifecycle.
            }
        }

        private static string FindPowerShell()
        {
            string candidate = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            return File.Exists(candidate) ? candidate : "powershell.exe";
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string ShortMessage(string message)
        {
            if (string.IsNullOrWhiteSpace(message)) return "Tidak dapat menjalankan worker.";
            return message.Length > 120 ? message.Substring(0, 120) : message;
        }

        private static string DefaultMessage(string status)
        {
            switch (status)
            {
                case "Memulai": return "Menyiapkan pemantauan Spotify.";
                case "Aktif": return "Pemantauan Spotify aktif.";
                case "Memulihkan": return "Memulihkan Spotify.";
                case "Menghentikan": return "Menghentikan pemantauan.";
                case "Off": return "Pemantauan berhenti.";
                default: return "";
            }
        }

        private static bool TryParseStatus(string line, out WorkerMessage message)
        {
            message = null;
            try
            {
                using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(line)))
                {
                    var serializer = new DataContractJsonSerializer(typeof(WorkerMessage));
                    message = serializer.ReadObject(stream) as WorkerMessage;
                }
                return message != null && !string.IsNullOrWhiteSpace(message.Status);
            }
            catch
            {
                return false;
            }
        }

        private void PrepareOverlay(WorkerMessage message)
        {
            if (stopRequested || overlayContext != null || overlayCaptureTask != null || string.IsNullOrWhiteSpace(message.RecoveryId)
                || closedRecoveryIds.Contains(message.RecoveryId)
                || string.IsNullOrWhiteSpace(message.EventName) || message.ProcessId <= 0 || message.WindowHandle == 0)
            {
                return;
            }

            IntPtr windowHandle = new IntPtr(message.WindowHandle);
            if (!NativeMethods.IsWindow(windowHandle) || NativeMethods.IsIconic(windowHandle)
                || NativeMethods.GetForegroundWindow() != windowHandle
                || GetWindowProcessId(windowHandle) != message.ProcessId)
            {
                return;
            }

            NativeMethods.Rect nativeRect;
            if (!NativeMethods.GetWindowRect(windowHandle, out nativeRect))
            {
                return;
            }

            int width = nativeRect.Right - nativeRect.Left;
            int height = nativeRect.Bottom - nativeRect.Top;
            long bytes = (long)width * height * 4L;
            if (width <= 0 || height <= 0 || bytes <= 0 || bytes > MaxBitmapBytes)
            {
                return;
            }

            var bounds = new Rectangle(nativeRect.Left, nativeRect.Top, width, height);
            IntPtr monitorHandle = NativeMethods.MonitorFromWindow(windowHandle, NativeMethods.MonitorDefaultToNearest);
            Rectangle monitorBounds;
            if (monitorHandle == IntPtr.Zero || !TryGetMonitorBounds(monitorHandle, out monitorBounds))
            {
                return;
            }
            var context = new OverlayContext
            {
                RecoveryId = message.RecoveryId,
                EventName = message.EventName,
                ProcessId = message.ProcessId,
                WindowHandle = windowHandle,
                Bounds = bounds,
                MonitorHandle = monitorHandle,
                MonitorBounds = monitorBounds,
                Maximized = NativeMethods.IsZoomed(windowHandle),
                Dpi = GetWindowDpi(windowHandle),
                CaptureStartedUtc = DateTime.UtcNow,
                LastInputTick = NativeMethods.GetLastInputTick(),
                Generation = ++overlayGeneration
            };
            overlayContext = context;
            WriteUiLog("Overlay preparation accepted for recovery " + context.RecoveryId + ".");

            Task<OverlayCaptureResult> task;
            try
            {
                task = Task.Factory.StartNew<OverlayCaptureResult>(delegate
                {
                    Bitmap bitmap = null;
                    try
                    {
                        bitmap = new Bitmap(width, height, PixelFormat.Format32bppPArgb);
                        using (var graphics = Graphics.FromImage(bitmap))
                        {
                            graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                        }
                        return new OverlayCaptureResult { Bitmap = bitmap, Bounds = bounds };
                    }
                    catch
                    {
                        if (bitmap != null) bitmap.Dispose();
                        return null;
                    }
                });
            }
            catch
            {
                WriteUiLog("Overlay fallback for recovery " + context.RecoveryId + ": capture could not start.");
                ClearOverlayContext();
                return;
            }
            overlayCaptureTask = task;
            task.ContinueWith(delegate(Task<OverlayCaptureResult> completed)
            {
                PostToUi(delegate { CompleteOverlayCapture(context, completed); });
            }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        }

        private void CompleteOverlayCapture(OverlayContext context, Task<OverlayCaptureResult> task)
        {
            if (overlayCaptureTask == task)
            {
                overlayCaptureTask = null;
            }

            OverlayCaptureResult result = null;
            try { result = task.IsFaulted || task.IsCanceled ? null : task.Result; } catch { }

            bool valid = result != null && overlayContext == context && context.Generation == overlayGeneration
                && (DateTime.UtcNow - context.CaptureStartedUtc).TotalMilliseconds <= OverlayCaptureMaxMs
                && NativeMethods.IsWindow(context.WindowHandle)
                && !NativeMethods.IsIconic(context.WindowHandle)
                && NativeMethods.GetForegroundWindow() == context.WindowHandle
                && GetWindowProcessId(context.WindowHandle) == context.ProcessId
                && GetWindowDpi(context.WindowHandle) == context.Dpi;

            NativeMethods.Rect currentRect;
            if (valid && NativeMethods.GetWindowRect(context.WindowHandle, out currentRect))
            {
                valid = currentRect.Left == context.Bounds.Left && currentRect.Top == context.Bounds.Top
                    && currentRect.Right - currentRect.Left == context.Bounds.Width
                    && currentRect.Bottom - currentRect.Top == context.Bounds.Height;
            }

            if (!valid)
            {
                if (result != null && result.Bitmap != null) result.Bitmap.Dispose();
                WriteUiLog("Overlay fallback for recovery " + context.RecoveryId + ": capture validation failed after "
                    + (long)(DateTime.UtcNow - context.CaptureStartedUtc).TotalMilliseconds + " ms.");
                ClearOverlayContext();
                return;
            }

            try
            {
                overlay = new OverlayForm(result.Bitmap, context.Bounds, OverlayEscPressed);
                result.Bitmap = null; // OverlayForm owns the bitmap now.
                // Keep the captured frame above the short-lived shell windows
                // Windows may activate while the old Spotify process exits.
                // This is temporary: the flag is removed before handoff and
                // when the overlay is cancelled.
                overlay.TopMost = true;
                overlay.Show();
                overlay.Refresh();
                context.ShownUtc = DateTime.UtcNow;
                WriteUiLog("Overlay displayed for recovery " + context.RecoveryId + " after "
                    + (long)(context.ShownUtc - context.CaptureStartedUtc).TotalMilliseconds + " ms.");
                EnsureOverlayWatchTimer();

                // The final foreground check above is the only point at which
                // the temporary form is allowed to take focus.
                FocusWindow(overlay.Handle);
                using (var readyEvent = EventWaitHandle.OpenExisting(context.EventName))
                {
                    readyEvent.Set();
                }
            }
            catch
            {
                if (result.Bitmap != null) result.Bitmap.Dispose();
                WriteUiLog("Overlay fallback for recovery " + context.RecoveryId + ": display or handshake failed.");
                HideOverlay();
            }
        }

        private void EnsureOverlayWatchTimer()
        {
            if (overlayWatchTimer == null)
            {
                overlayWatchTimer = new System.Windows.Forms.Timer { Interval = 100 };
                overlayWatchTimer.Tick += OverlayWatchTimer_Tick;
            }
            overlayWatchTimer.Start();
        }

        private void OverlayWatchTimer_Tick(object sender, EventArgs e)
        {
            if (overlayContext == null || overlay == null || overlay.IsDisposed)
            {
                HideOverlay();
                return;
            }

            if (ContextElapsedMilliseconds(overlayContext) >= OverlayMaxMs)
            {
                WriteUiLog("Overlay expired after " + OverlayMaxMs + " ms for recovery " + overlayContext.RecoveryId + ".");
                HideOverlay();
                return;
            }

            IntPtr foreground = NativeMethods.GetForegroundWindow();
            if (foreground != overlay.Handle && foreground != overlayContext.WindowHandle)
            {
                // During teardown Windows can briefly move focus to a shell
                // window (or leave no foreground window) before the replacement
                // Spotify window exists. Keep the frame for that automatic
                // transition. A real Alt+Tab/click changes the system last-input
                // tick, so release immediately in that case.
                if (HasUserInputSince(overlayContext.LastInputTick))
                {
                    overlayContext.UserFocusChanged = true;
                    WriteUiLog("Overlay cancelled because foreground changed for recovery " + overlayContext.RecoveryId + ".");
                    HideOverlay();
                    return;
                }
            }

            IntPtr currentMonitor = NativeMethods.MonitorFromWindow(overlay.Handle, NativeMethods.MonitorDefaultToNearest);
            Rectangle currentMonitorBounds;
            if (currentMonitor != overlayContext.MonitorHandle
                || !TryGetMonitorBounds(currentMonitor, out currentMonitorBounds)
                || currentMonitorBounds != overlayContext.MonitorBounds)
            {
                WriteUiLog("Overlay cancelled because monitor geometry changed for recovery " + overlayContext.RecoveryId + ".");
                HideOverlay();
            }
        }

        private static long ContextElapsedMilliseconds(OverlayContext context)
        {
            if (context.ShownUtc == DateTime.MinValue) return 0;
            return (long)(DateTime.UtcNow - context.ShownUtc).TotalMilliseconds;
        }

        private void OverlayEscPressed()
        {
            HideOverlay();
        }

        private void ReleaseOverlay(WorkerMessage message)
        {
            if (!string.IsNullOrWhiteSpace(message.RecoveryId) && closedRecoveryIds.Contains(message.RecoveryId))
            {
                return;
            }
            if (overlayContext == null)
            {
                RememberClosedRecovery(message.RecoveryId);
                return;
            }
            if (string.IsNullOrWhiteSpace(message.RecoveryId)
                || !string.Equals(message.RecoveryId, overlayContext.RecoveryId, StringComparison.Ordinal))
            {
                RememberClosedRecovery(message.RecoveryId);
                return;
            }

            pendingHandoff = message;
            handoffRequestedUtc = DateTime.UtcNow;
            handoffReadyStableChecks = 0;
            handoffLastTitle = null;
            if (overlay == null || overlay.IsDisposed)
            {
                ClearOverlayContext();
                return;
            }

            if (handoffTimer == null)
            {
                handoffTimer = new System.Windows.Forms.Timer();
                handoffTimer.Tick += HandoffTimer_Tick;
            }
            // A successful recovery carries the replacement window identity.
            // Poll readiness after a short minimum hold so the new Spotify UI
            // has time to paint. A failed recovery keeps the short grace period.
            handoffTimer.Interval = message.ProcessId > 0 && message.WindowHandle != 0
                ? HandoffPollIntervalMs
                : OverlayRenderDelayMs;
            handoffTimer.Stop();
            handoffTimer.Start();
        }

        private void HandoffTimer_Tick(object sender, EventArgs e)
        {
            if (pendingHandoff != null && pendingHandoff.ProcessId > 0 && pendingHandoff.WindowHandle != 0)
            {
                if ((DateTime.UtcNow - handoffRequestedUtc).TotalMilliseconds < OverlayPostPlayMinimumMs)
                {
                    return;
                }

                TryFinishOverlayHandoff(pendingHandoff);
                if (overlayContext != null && ContextElapsedMilliseconds(overlayContext) < OverlayMaxMs)
                {
                    return;
                }
                pendingHandoff = null;
                handoffTimer.Stop();
                return;
            }

            handoffTimer.Stop();
            TryFinishOverlayHandoff(pendingHandoff);
            pendingHandoff = null;
        }

        private void TryFinishOverlayHandoff(WorkerMessage message)
        {
            if (overlayContext == null || overlay == null || overlay.IsDisposed)
            {
                return;
            }

            bool keepFocus = !overlayContext.UserFocusChanged;
            IntPtr newHandle = message == null ? IntPtr.Zero : new IntPtr(message.WindowHandle);
            if (newHandle != IntPtr.Zero && message.ProcessId > 0
                && NativeMethods.IsWindow(newHandle)
                && NativeMethods.IsWindowVisible(newHandle)
                && !NativeMethods.IsHungAppWindow(newHandle)
                && GetWindowProcessId(newHandle) == message.ProcessId
                && IsSpotifyProcess(message.ProcessId))
            {
                string title = GetWindowTitle(newHandle);
                if (!string.Equals(title, handoffLastTitle, StringComparison.Ordinal))
                {
                    handoffLastTitle = title;
                    handoffReadyStableChecks = 1;
                }
                else
                {
                    handoffReadyStableChecks++;
                }

                // Ask Spotify to paint any pending invalid region, then wait
                // for the compositor to submit the frame. These calls only run
                // during an active handoff timer; idle monitoring is unchanged.
                try { NativeMethods.UpdateWindow(newHandle); } catch { }
                try { NativeMethods.DwmFlush(); } catch { }

                if (handoffReadyStableChecks < HandoffReadyStableChecks)
                {
                    return;
                }

                string recoveryId = overlayContext.RecoveryId;
                overlay.TopMost = false;
                RestoreSpotifyWindow(newHandle, overlayContext);
                NativeMethods.SetWindowPos(overlay.Handle, NativeMethods.HwndTop, 0, 0, 0, 0,
                    NativeMethods.SwpNoActivate | NativeMethods.SwpNoMove | NativeMethods.SwpNoSize | NativeMethods.SwpShowWindow);

                long elapsed = ContextElapsedMilliseconds(overlayContext);
                int stableChecks = handoffReadyStableChecks;
                HideOverlay();
                bool focusGranted = false;
                if (keepFocus && NativeMethods.IsWindow(newHandle))
                {
                    focusGranted = FocusWindow(newHandle);
                }
                WriteUiLog("Overlay handoff completed for recovery " + recoveryId + " after "
                    + elapsed + " ms; stableChecks=" + stableChecks + "; focus="
                    + (focusGranted ? "granted" : (keepFocus ? "not-granted" : "not-requested")) + ".");
                return;
            }

            // A replacement process can expose its main window shortly after
            // the worker reports it. Keep the old frame until the eight-second
            // absolute limit instead of revealing a loading/black window.
            if (message != null && message.ProcessId > 0 && ContextElapsedMilliseconds(overlayContext) < OverlayMaxMs)
            {
                return;
            }

            // A failed or stop-only recovery must never leave the old frame on
            // screen while waiting for a window that will not arrive.
            WriteUiLog("Overlay fallback for recovery " + overlayContext.RecoveryId + ": replacement window unavailable after "
                + ContextElapsedMilliseconds(overlayContext) + " ms.");
            HideOverlay();
        }

        private static bool IsSpotifyProcess(int processId)
        {
            try
            {
                using (var process = Process.GetProcessById(processId))
                {
                    return string.Equals(process.ProcessName, "Spotify", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch
            {
                return false;
            }
        }

        private static bool IsShellTransitionWindow(IntPtr handle)
        {
            if (handle == IntPtr.Zero) return true;
            int processId = GetWindowProcessId(handle);
            if (processId == 0) return true;
            try
            {
                using (var process = Process.GetProcessById(processId))
                {
                    string name = process.ProcessName;
                    return string.Equals(name, "explorer", StringComparison.OrdinalIgnoreCase)
                        || string.Equals(name, "ShellExperienceHost", StringComparison.OrdinalIgnoreCase)
                        || string.Equals(name, "SearchHost", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch
            {
                return false;
            }
        }

        private static bool HasUserInputSince(uint previousTick)
        {
            uint currentTick = NativeMethods.GetLastInputTick();
            return previousTick != 0 && currentTick != 0 && currentTick != previousTick;
        }

        private static void RestoreSpotifyWindow(IntPtr handle, OverlayContext context)
        {
            if (NativeMethods.IsIconic(handle))
            {
                NativeMethods.ShowWindow(handle, NativeMethods.SwRestore);
            }
            NativeMethods.SetWindowPos(handle, NativeMethods.HwndTop,
                context.Bounds.Left, context.Bounds.Top, context.Bounds.Width, context.Bounds.Height,
                NativeMethods.SwpNoActivate | NativeMethods.SwpShowWindow);
            if (context.Maximized)
            {
                NativeMethods.ShowWindow(handle, NativeMethods.SwMaximize);
            }
            else
            {
                NativeMethods.ShowWindow(handle, NativeMethods.SwShowNoActivate);
            }
        }

        private void ClearOverlayContext()
        {
            RememberClosedRecovery(overlayContext == null ? null : overlayContext.RecoveryId);
            overlayContext = null;
            pendingHandoff = null;
            handoffRequestedUtc = DateTime.MinValue;
            handoffReadyStableChecks = 0;
            handoffLastTitle = null;
            if (handoffTimer != null) handoffTimer.Stop();
        }

        private void HideOverlay()
        {
            if (overlayWatchTimer != null) overlayWatchTimer.Stop();
            if (handoffTimer != null) handoffTimer.Stop();
            pendingHandoff = null;
            handoffRequestedUtc = DateTime.MinValue;
            handoffReadyStableChecks = 0;
            handoffLastTitle = null;

            if (overlay != null)
            {
                try { overlay.TopMost = false; } catch { }
                try { overlay.Hide(); } catch { }
                try { overlay.Dispose(); } catch { }
                overlay = null;
            }
            RememberClosedRecovery(overlayContext == null ? null : overlayContext.RecoveryId);
            overlayContext = null;
        }

        private void RememberClosedRecovery(string recoveryId)
        {
            if (string.IsNullOrWhiteSpace(recoveryId) || closedRecoveryIds.Contains(recoveryId)) return;
            closedRecoveryIds.Add(recoveryId);
            closedRecoveryOrder.Enqueue(recoveryId);
            while (closedRecoveryOrder.Count > 32)
            {
                closedRecoveryIds.Remove(closedRecoveryOrder.Dequeue());
            }
        }

        private static int GetWindowProcessId(IntPtr handle)
        {
            uint processId;
            NativeMethods.GetWindowThreadProcessId(handle, out processId);
            return unchecked((int)processId);
        }

        private static string GetWindowTitle(IntPtr handle)
        {
            if (handle == IntPtr.Zero) return string.Empty;
            var title = new StringBuilder(512);
            NativeMethods.GetWindowText(handle, title, title.Capacity);
            return title.ToString();
        }

        private static bool FocusWindow(IntPtr handle)
        {
            if (handle == IntPtr.Zero || !NativeMethods.IsWindow(handle)) return false;

            IntPtr foreground = NativeMethods.GetForegroundWindow();
            uint currentThread = NativeMethods.GetCurrentThreadId();
            uint foregroundProcess;
            uint targetProcess;
            uint foregroundThread = foreground == IntPtr.Zero
                ? 0
                : NativeMethods.GetWindowThreadProcessId(foreground, out foregroundProcess);
            uint targetThread = NativeMethods.GetWindowThreadProcessId(handle, out targetProcess);
            bool attachedForeground = false;
            bool attachedTarget = false;

            try
            {
                // Windows may reject SetForegroundWindow when the worker UI is
                // no longer the foreground process. Temporarily sharing the
                // input queue is the documented desktop-app activation pattern;
                // the queues are detached immediately after the call.
                if (foregroundThread != 0 && foregroundThread != currentThread)
                {
                    attachedForeground = NativeMethods.AttachThreadInput(currentThread, foregroundThread, true);
                }
                if (targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread)
                {
                    attachedTarget = NativeMethods.AttachThreadInput(currentThread, targetThread, true);
                }

                NativeMethods.BringWindowToTop(handle);
                NativeMethods.SetForegroundWindow(handle);
                return NativeMethods.GetForegroundWindow() == handle;
            }
            finally
            {
                if (attachedTarget)
                {
                    try { NativeMethods.AttachThreadInput(currentThread, targetThread, false); } catch { }
                }
                if (attachedForeground)
                {
                    try { NativeMethods.AttachThreadInput(currentThread, foregroundThread, false); } catch { }
                }
            }
        }

        private static int GetWindowDpi(IntPtr handle)
        {
            try { return NativeMethods.GetDpiForWindow(handle); }
            catch { return 0; }
        }

        private static bool TryGetMonitorBounds(IntPtr monitor, out Rectangle bounds)
        {
            bounds = Rectangle.Empty;
            if (monitor == IntPtr.Zero) return false;

            NativeMethods.MonitorInfo info = new NativeMethods.MonitorInfo();
            info.CbSize = (uint)Marshal.SizeOf(typeof(NativeMethods.MonitorInfo));
            if (!NativeMethods.GetMonitorInfo(monitor, ref info)) return false;
            bounds = new Rectangle(info.Monitor.Left, info.Monitor.Top,
                info.Monitor.Right - info.Monitor.Left, info.Monitor.Bottom - info.Monitor.Top);
            return bounds.Width > 0 && bounds.Height > 0;
        }

        private sealed class OverlayContext
        {
            public string RecoveryId;
            public string EventName;
            public int ProcessId;
            public IntPtr WindowHandle;
            public Rectangle Bounds;
            public IntPtr MonitorHandle;
            public Rectangle MonitorBounds;
            public bool Maximized;
            public int Dpi;
            public DateTime CaptureStartedUtc;
            public DateTime ShownUtc;
            public uint LastInputTick;
            public bool UserFocusChanged;
            public int Generation;
        }

        private sealed class OverlayCaptureResult
        {
            public Bitmap Bitmap;
            public Rectangle Bounds;
        }

        private sealed class SkiptifyToggle : Control
        {
            private bool checkedValue;
            private bool pressed;

            public SkiptifyToggle()
            {
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                    | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
                    | ControlStyles.SupportsTransparentBackColor, true);
                ForeColor = Color.White;
                AccessibleRole = AccessibleRole.PushButton;
                TabStop = true;
                Cursor = Cursors.Hand;
            }

            public bool Checked
            {
                get { return checkedValue; }
                set
                {
                    if (checkedValue == value) return;
                    checkedValue = value;
                    Invalidate();
                }
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                base.OnPaint(e);
                Graphics graphics = e.Graphics;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                float radius = Width / 2f - 1f;
                RectangleF pill = new RectangleF(1, 1, Width - 2, Height - 2);
                using (var path = CreateRoundedPath(Rectangle.Round(pill), radius))
                using (var activeBrush = new LinearGradientBrush(new Point(0, 0), new Point(0, Height),
                    Color.FromArgb(0, 225, 143), Color.FromArgb(0, 177, 107)))
                using (var offBrush = new SolidBrush(Color.FromArgb(8, 27, 32)))
                using (var border = new Pen(Color.FromArgb(0, 225, 143), 2f))
                {
                    graphics.FillPath(checkedValue ? (Brush)activeBrush : offBrush, path);
                    graphics.DrawPath(border, path);
                }

                float knobSize = Width - 14f;
                float knobY = checkedValue ? 7f : Height - knobSize - 7f;
                using (var knobBrush = new SolidBrush(checkedValue
                    ? Color.FromArgb(248, 252, 250)
                    : Color.FromArgb(102, 132, 137)))
                {
                    graphics.FillEllipse(knobBrush, (Width - knobSize) / 2f, knobY, knobSize, knobSize);
                }

                using (var textFont = new Font("Segoe UI", Math.Max(13f, Width * 0.23f), FontStyle.Bold))
                using (var textBrush = new SolidBrush(Enabled
                    ? Color.FromArgb(248, 252, 250)
                    : Color.FromArgb(150, 170, 174)))
                {
                    var format = new StringFormat
                    {
                        Alignment = StringAlignment.Center,
                        LineAlignment = StringAlignment.Center
                    };
                    RectangleF textBounds = checkedValue
                        ? new RectangleF(0, knobSize + 14f, Width, Height - knobSize - 21f)
                        : new RectangleF(0, 7f, Width, Height - knobSize - 21f);
                    graphics.DrawString(Text ?? (checkedValue ? "ON" : "OFF"), textFont, textBrush,
                        textBounds, format);
                }

            }

            protected override void OnCreateControl()
            {
                base.OnCreateControl();
                BackColor = Color.Transparent;
            }

            protected override void OnMouseDown(MouseEventArgs e)
            {
                base.OnMouseDown(e);
                if (e.Button == MouseButtons.Left && Enabled)
                {
                    pressed = true;
                    Focus();
                    Invalidate();
                }
            }

            protected override void OnMouseUp(MouseEventArgs e)
            {
                base.OnMouseUp(e);
                bool activate = pressed && e.Button == MouseButtons.Left
                    && ClientRectangle.Contains(e.Location) && Enabled;
                pressed = false;
                if (activate)
                {
                    Checked = !Checked;
                    OnClick(EventArgs.Empty);
                }
                Invalidate();
            }

            protected override void OnKeyDown(KeyEventArgs e)
            {
                if ((e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) && Enabled)
                {
                    Checked = !Checked;
                    OnClick(EventArgs.Empty);
                    e.Handled = true;
                    return;
                }
                base.OnKeyDown(e);
            }
        }

        private enum ChromeButtonKind
        {
            Minimize,
            Maximize,
            Close
        }

        private sealed class ChromeButton : Control
        {
            private readonly ChromeButtonKind kind;
            private bool hovered;
            private bool maximized;

            public ChromeButton(ChromeButtonKind kind)
            {
                this.kind = kind;
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint
                    | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
                    | ControlStyles.SupportsTransparentBackColor, true);
                // Let WinForms dispatch exactly one Click per mouse release.
                // A rapid second click is another button press, not a title-bar
                // double-click gesture.
                SetStyle(ControlStyles.StandardClick, true);
                SetStyle(ControlStyles.StandardDoubleClick, false);
                ForeColor = Color.White;
                AccessibleRole = AccessibleRole.PushButton;
                TabStop = true;
                Cursor = Cursors.Hand;
            }

            public bool IsMaximized
            {
                get { return maximized; }
                set
                {
                    if (maximized == value) return;
                    maximized = value;
                    Invalidate();
                }
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                base.OnPaint(e);
                Graphics graphics = e.Graphics;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                if (hovered)
                {
                    using (var hoverBrush = new SolidBrush(kind == ChromeButtonKind.Close
                        ? Color.FromArgb(175, 194, 55, 55)
                        : Color.FromArgb(50, 255, 255, 255)))
                    {
                        graphics.FillRectangle(hoverBrush, ClientRectangle);
                    }
                }

                using (var glyphPen = new Pen(Color.FromArgb(245, 250, 249), Math.Max(2f, Height * 0.035f)))
                {
                    glyphPen.StartCap = LineCap.Round;
                    glyphPen.EndCap = LineCap.Round;
                    float centerX = Width / 2f;
                    float centerY = Height / 2f;
                    float glyph = Math.Min(18f, Math.Min(Width, Height) * 0.24f);
                    if (kind == ChromeButtonKind.Minimize)
                    {
                        graphics.DrawLine(glyphPen, centerX - glyph, centerY + glyph * 0.45f,
                            centerX + glyph, centerY + glyph * 0.45f);
                    }
                    else if (kind == ChromeButtonKind.Maximize)
                    {
                        if (maximized)
                        {
                            graphics.DrawRectangle(glyphPen, centerX - glyph + 3, centerY - glyph + 3,
                                glyph * 1.45f, glyph * 1.45f);
                            graphics.DrawRectangle(glyphPen, centerX - glyph - 3, centerY - glyph - 3,
                                glyph * 1.45f, glyph * 1.45f);
                        }
                        else
                        {
                            graphics.DrawRectangle(glyphPen, centerX - glyph, centerY - glyph,
                                glyph * 2f, glyph * 2f);
                        }
                    }
                    else
                    {
                        graphics.DrawLine(glyphPen, centerX - glyph, centerY - glyph,
                            centerX + glyph, centerY + glyph);
                        graphics.DrawLine(glyphPen, centerX + glyph, centerY - glyph,
                            centerX - glyph, centerY + glyph);
                    }
                }

            }

            protected override void OnCreateControl()
            {
                base.OnCreateControl();
                BackColor = Color.Transparent;
            }

            protected override void OnMouseEnter(EventArgs e)
            {
                hovered = true;
                Invalidate();
                base.OnMouseEnter(e);
            }

            protected override void OnMouseLeave(EventArgs e)
            {
                hovered = false;
                Invalidate();
                base.OnMouseLeave(e);
            }

            protected override void OnMouseDown(MouseEventArgs e)
            {
                base.OnMouseDown(e);
                if (e.Button == MouseButtons.Left && Enabled)
                {
                    Focus();
                    Invalidate();
                }
            }

            protected override void OnKeyDown(KeyEventArgs e)
            {
                if ((e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) && Enabled)
                {
                    OnClick(EventArgs.Empty);
                    e.Handled = true;
                    return;
                }
                base.OnKeyDown(e);
            }
        }

        private sealed class OverlayForm : Form
        {
            private readonly Action escAction;
            private readonly PictureBox picture;

            public OverlayForm(Bitmap bitmap, Rectangle bounds, Action escAction)
            {
                this.escAction = escAction;
                FormBorderStyle = FormBorderStyle.None;
                ShowInTaskbar = false;
                StartPosition = FormStartPosition.Manual;
                AutoScaleMode = AutoScaleMode.None;
                Bounds = bounds;
                KeyPreview = true;
                BackColor = Color.Black;
                picture = new PictureBox
                {
                    Dock = DockStyle.Fill,
                    Image = bitmap,
                    SizeMode = PictureBoxSizeMode.Normal,
                    BackColor = Color.Black
                };
                Controls.Add(picture);
                KeyDown += OverlayForm_KeyDown;
            }

            private void OverlayForm_KeyDown(object sender, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Escape)
                {
                    e.Handled = true;
                    if (escAction != null) escAction();
                }
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing && picture != null)
                {
                    Image image = picture.Image;
                    picture.Image = null;
                    if (image != null) image.Dispose();
                    picture.Dispose();
                }
                base.Dispose(disposing);
            }
        }

        private static class NativeMethods
        {
            public const int WmNcLButtonDown = 0x00A1;
            public const int HTCaption = 2;
            public const int SwRestore = 9;
            public const int SwMaximize = 3;
            public const int SwShowNoActivate = 4;
            public const uint SwpNoActivate = 0x0010;
            public const uint SwpNoMove = 0x0002;
            public const uint SwpNoSize = 0x0001;
            public const uint SwpShowWindow = 0x0040;
            public const uint MonitorDefaultToNearest = 0x00000002;
            public static readonly IntPtr HwndTop = new IntPtr(-1);
            public static readonly IntPtr DpiAwarenessContextPerMonitorV2 = new IntPtr(-4);

            [StructLayout(LayoutKind.Sequential)]
            public struct MonitorInfo
            {
                public uint CbSize;
                public Rect Monitor;
                public Rect Work;
                public uint Flags;
            }

            [StructLayout(LayoutKind.Sequential)]
            public struct Rect
            {
                public int Left;
                public int Top;
                public int Right;
                public int Bottom;
            }

            [DllImport("user32.dll", CharSet = CharSet.Unicode)]
            public static extern IntPtr FindWindow(string className, string windowName);

            public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

            [DllImport("user32.dll")]
            public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

            [DllImport("user32.dll", CharSet = CharSet.Unicode)]
            public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

            [DllImport("user32.dll")]
            public static extern bool ShowWindow(IntPtr hWnd, int command);

            [DllImport("user32.dll")]
            public static extern bool SetForegroundWindow(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool BringWindowToTop(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool ReleaseCapture();

            [DllImport("user32.dll")]
            public static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

            [DllImport("user32.dll")]
            public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

            [DllImport("kernel32.dll")]
            public static extern uint GetCurrentThreadId();

            [DllImport("user32.dll")]
            public static extern IntPtr GetForegroundWindow();

            [StructLayout(LayoutKind.Sequential)]
            private struct LastInputInfo
            {
                public uint CbSize;
                public uint DwTime;
            }

            [DllImport("user32.dll")]
            private static extern bool GetLastInputInfo(ref LastInputInfo info);

            public static uint GetLastInputTick()
            {
                var info = new LastInputInfo { CbSize = (uint)Marshal.SizeOf(typeof(LastInputInfo)) };
                return GetLastInputInfo(ref info) ? info.DwTime : 0;
            }

            [DllImport("user32.dll")]
            public static extern bool IsWindow(IntPtr hWnd);

            [DllImport("user32.dll", SetLastError = true)]
            public static extern bool DestroyIcon(IntPtr hIcon);

            [DllImport("user32.dll")]
            public static extern bool IsWindowVisible(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool UpdateWindow(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool IsIconic(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool IsZoomed(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);

            [DllImport("user32.dll")]
            public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

            [DllImport("user32.dll", SetLastError = true)]
            public static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

            [DllImport("user32.dll")]
            public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

            [DllImport("user32.dll")]
            public static extern bool IsHungAppWindow(IntPtr hWnd);

            [DllImport("user32.dll", SetLastError = true)]
            public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

            [DllImport("user32.dll")]
            public static extern int GetDpiForWindow(IntPtr hWnd);

            [DllImport("user32.dll", SetLastError = true)]
            public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

            [DllImport("dwmapi.dll")]
            public static extern int DwmFlush();
        }
    }
}

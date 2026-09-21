# Skiptify Desktop 1.1

Skiptify Desktop is a lightweight Windows UI with a single On/Off toggle. The main view uses a dark-green theme with the Skiptify logo, simple window controls, and short error messages only when needed. The monitoring engine still uses `skiptify/skiptify.ps1`, so Spotify detection and recovery behave the same as in the VBS/PS1 version. When Spotify is in the foreground, Desktop can show a temporary snapshot during recovery so the app switch looks like a brief pause.

## Build

Run from PowerShell 5.1 in the project folder:

```powershell
.\build.ps1
```

The output is in `dist\Skiptify.exe`, along with the PowerShell worker and the VBS launcher. Compilation uses the C# compiler bundled with .NET Framework 4.8, with no NuGet dependencies or browser runtime.

The `Skiptify Logo.png` logo is embedded in the executable as the header logo, main logo, watermark, and window/taskbar icon. `Skiptify.ico` serves as the multi-size Windows icon resource for the executable and shortcuts. The PNG/ICO files do not need to be copied to the installation folder at runtime. The UI uses no animation timers or external UI dependencies; images and fonts are redrawn only when the status or window size changes.

To build the installer:

```powershell
.\build.ps1 -Installer
```

This command requires Inno Setup 6 (`ISCC.exe`) and produces `dist\Skiptify-Setup-1.1.exe`. The installer installs per user to `%LOCALAPPDATA%\Programs\Skiptify`, creates a Start Menu shortcut, and offers a desktop shortcut.

## Running

Open `Skiptify.exe`, press **On**, and leave the app running in the taskbar. Press **Off** to stop the worker; Spotify is not closed. Clicking **X** stops the worker in an orderly way and then exits.

The UI uses the mutex `Local\Skiptify.Desktop.1.0`; the worker uses the mutex `Local\Skiptify.Engine.1.0`. As a result, only one UI and one worker can run per user session. The **Start/Stop Skiptify.vbs** button uses the same stop event as the UI.

The snapshot is stored in RAM only, captured once from the visible Spotify area, and limited to 64 MiB. The capture is canceled if Spotify is no longer in the foreground, its position or DPI changes, the user switches apps, or preparation exceeds 500 ms. While the old Spotify process is being closed, the overlay is temporarily kept on top so that Windows focus changes do not reveal the desktop; after Play is sent, the frame is held for at least 1.5 seconds and until three window checks are stable. The handoff requests one render and a Windows compositor flush, uses temporary Win32 focus activation, and is released if the user switches apps. The overlay is released after 8 seconds at most; Esc, Off, and X always clear it.

During recovery, the worker asks Spotify to close gracefully with `WM_CLOSE` and a 1-second timeout. Force-stop is used only for Spotify PIDs that are still alive after an additional wait period. If Windows shows a `Spotify.exe - Application Error` dialog, the worker stops recovery with a short message and does not automatically retry the launch; the popup is left for the user to handle.

On first launch, when Spotify does not yet have a responsive window, Desktop and the VBS launcher use normal startup mode, including when a Spotify process is still running in the background. An existing hidden Spotify window is shown again without launching a new process. Startup waits up to 30 seconds. Recovery without a ready overlay also uses Spotify's built-in `--minimized` argument to prevent the startup window from appearing before polling minimizes it. Recovery launches Spotify in minimized mode so its window can still be detected; Hidden mode can leave a process with no detectable window. The temporary `Spotify` title is ignored, and the worker allows a 4-second stabilization period so that startup is not mistaken for an ad or trigger a second recovery.

Runtime logs are stored in `%LOCALAPPDATA%\Skiptify\Logs\skiptify.log` with one rotated archive of up to 1 MB. If that folder is not writable, the worker falls back to the script folder and continues monitoring.

## Verification

```powershell
Invoke-Pester -Script .\tests\skiptify.tests.ps1 -EnableExit
```

The tests cover 25 worker scenarios, window stability, minimized launch, named events, visible startup, Application Error handling, and mutex lifecycle. CPU/RAM measurements, live Spotify restart tests, and recordings of the visual transitions still need to be done on the user's machine before wider distribution.

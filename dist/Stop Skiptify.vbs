Set shell = CreateObject("WScript.Shell")

cmd = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " & _
      """try { $event = [Threading.EventWaitHandle]::OpenExisting('Local\Skiptify.Stop.1.0'); $event.Set(); $event.Dispose() } catch { }"""

shell.Run cmd, 0, True

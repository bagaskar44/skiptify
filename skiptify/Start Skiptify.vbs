Set fso = CreateObject("Scripting.FileSystemObject")

folder = fso.GetParentFolderName(WScript.ScriptFullName)

Set shell = CreateObject("WScript.Shell")

shell.Run _
    "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & folder & "\skiptify.ps1"" -StopEventName ""Local\Skiptify.Stop.1.0"" -VisibleStartup", _
    0, False

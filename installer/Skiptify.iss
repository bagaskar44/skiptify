#define MyAppName "Skiptify"
#define MyAppVersion "1.1"
#define MyAppPublisher "Skiptify"
#define MyAppExeName "Skiptify.exe"

[Setup]
AppId={{B54EA2E4-7B10-4E0E-BB20-8F0D8D9D8B01}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Skiptify
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Skiptify-Setup-1.1
Compression=lzma
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
CloseApplicationsFilter=Skiptify.exe
RestartApplications=no

[Files]
Source: "..\dist\Skiptify.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\Skiptify.exe.config"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\skiptify.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\Start Skiptify.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\Stop Skiptify.vbs"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Skiptify"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Skiptify"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Buat shortcut di desktop"; GroupDescription: "Shortcut tambahan:"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[UninstallRun]
Filename: "{app}\Stop Skiptify.vbs"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "StopSkiptify"

[Code]
function InitializeSetup(): Boolean;
var
  Release: Cardinal;
begin
  Result := True;
  if not RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release) then
  begin
    MsgBox('Skiptify memerlukan .NET Framework 4.8 atau lebih baru.', mbError, MB_OK);
    Result := False;
    exit;
  end;
  if Release < 528040 then
  begin
    MsgBox('Skiptify memerlukan .NET Framework 4.8 atau lebih baru.', mbError, MB_OK);
    Result := False;
    exit;
  end;
  if not FileExists(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe')) then
  begin
    MsgBox('Windows PowerShell 5.1 tidak ditemukan.', mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  { Ask an existing worker to stop before files are replaced. CloseApplications
    then closes the UI and waits for its normal FormClosing path. }
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ""try { $e = [Threading.EventWaitHandle]::OpenExisting(''Local\Skiptify.Stop.1.0''); $e.Set(); $e.Dispose() } catch { }""',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

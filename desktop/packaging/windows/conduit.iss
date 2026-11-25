; Conduit Desktop for Windows (x64): an installer per user, with no
; administrator and no UAC prompt, into %LOCALAPPDATA%\Programs\Conduit.
; Unsigned for now. build.ps1 stages the files and compiles this; by hand,
; with Inno Setup 6.3 or later:
;
;   iscc /DAppVersion=1.2.0 /DFileVersion=1.2.0.0 /DStageDir=<staged folder> /DOutputDir=<out> conduit.iss
;
; Every text the installer shows is Inno Setup's own, in its translations
; of the app's languages (Chinese has none, so it gets English).
;
; Uninstalling closes a running Conduit and its conduitd first, as Setup
; does ([Code]), then removes what this installed: the app's folder, its Start menu
; entry and its registrations. The user's data
; (%LOCALAPPDATA%\Conduit\User Data, its logs, the key in Credential
; Manager, the updater's settings in HKCU\Software\Conduit\Updates) is
; the app's, never the installer's, and stays.

#if Ver < EncodeVer(6, 3, 0)
  #error Inno Setup 6.3 or later is needed (x64compatible)
#endif
; [Code]'s Restart Manager calls pass pointers as Cardinal: Setup and
; Uninstall are 32-bit through Inno Setup 6.
#if Ver >= EncodeVer(7, 0, 0)
  #error Check the Restart Manager declarations in [Code] for a 64-bit Uninstall
#endif
#ifndef AppVersion
  #error Pass /DAppVersion=X.Y.Z (build.ps1 does)
#endif
#ifndef FileVersion
  #error Pass /DFileVersion=X.Y.Z.0 (build.ps1 does)
#endif
#ifndef StageDir
  #error Pass /DStageDir=<the staged install folder> (build.ps1 does)
#endif
#ifndef OutputDir
  #error Pass /DOutputDir=<where the installer goes> (build.ps1 does)
#endif

; Who the installed app is to Windows (its entry in Installed apps, which
; an upgrade replaces): never changed once a version has shipped, or an
; upgrade installs a second copy beside the first. smoke.ps1 reads it here.
#define AppGuid "536D4CBE-1A63-41FD-94E6-E05B2555BECC"
#define AppName "Conduit"

[Setup]
AppId={{{#AppGuid}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisherURL=https://github.com/cogwheel0/conduit
AppSupportURL=https://github.com/cogwheel0/conduit/issues
AppUpdatesURL=https://github.com/cogwheel0/conduit/releases
VersionInfoVersion={#FileVersion}
UninstallDisplayName=Conduit
UninstallDisplayIcon={app}\conduit.ico
SetupIconFile=conduit.ico
; Per user: {autopf} is %LOCALAPPDATA%\Programs, the registry root HKCU.
PrivilegesRequired=lowest
DefaultDirName={autopf}\Conduit
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Rust's Windows target needs Windows 10.
MinVersion=10.0
; A running Conduit and its conduitd hold files this replaces: [Code]
; closes both first (PrepareToInstall; run by hand, Setup asks), forced if
; they don't close, and nothing else. Inno's own CloseApplications would
; shut down every program and service with those files open. Setup doesn't
; start the app again: an interactive install offers to at the end, and an
; update WinSparkle runs does it ([Run]).
CloseApplications=no
ChangesAssociations=yes
ShowLanguageDialog=no
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=Conduit-{#AppVersion}-windows-x64-setup

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "cs"; MessagesFile: "compiler:Languages\Czech.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "ko"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "nl"; MessagesFile: "compiler:Languages\Dutch.isl"
Name: "pl"; MessagesFile: "compiler:Languages\Polish.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "sk"; MessagesFile: "compiler:Languages\Slovak.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The app with conduitd beside it (conduitd\bin\conduitd.exe and its
; libraries), where paths::packaged_daemon_for looks.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Conduit"; Filename: "{app}\conduit-desktop.exe"; IconFilename: "{app}\conduit.ico"
Name: "{autodesktop}\Conduit"; Filename: "{app}\conduit-desktop.exe"; IconFilename: "{app}\conduit.ico"; Tasks: desktopicon

[Registry]
; conduit:// links.
Root: HKCU; Subkey: "Software\Classes\conduit"; ValueType: string; ValueName: ""; ValueData: "URL:Conduit"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\conduit"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\conduit\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\conduit.ico"
Root: HKCU; Subkey: "Software\Classes\conduit\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\conduit-desktop.exe"" ""%1"""
; Open With for the Mac's document types (Info.plist; winlinux.py checks
; the two lists match), never as the default app for any of them.
Root: HKCU; Subkey: "Software\Classes\Conduit.File"; ValueType: string; ValueName: ""; ValueData: "Conduit"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Conduit.File\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\conduit.ico"
Root: HKCU; Subkey: "Software\Classes\Conduit.File\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\conduit-desktop.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Conduit"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\conduit.ico"
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\conduit-desktop.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\.pdf\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.txt\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.md\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.markdown\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.csv\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.json\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.docx\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.xlsx\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.pptx\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.png\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.jpg\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.jpeg\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.gif\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.webp\OpenWithProgids"; ValueType: string; ValueName: "Conduit.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".pdf"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".txt"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".md"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".markdown"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".csv"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".json"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".docx"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".xlsx"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".pptx"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".png"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".jpg"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".jpeg"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".gif"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\Applications\conduit-desktop.exe\SupportedTypes"; ValueType: string; ValueName: ".webp"; ValueData: ""

[Run]
Filename: "{app}\conduit-desktop.exe"; Description: "{cm:LaunchProgram,Conduit}"; Flags: nowait postinstall skipifsilent
; An update WinSparkle runs (/SILENT ... /RELAUNCH=1, the feed's
; sparkle:installerArguments: packaging/winlinux_feed.py) opens the app
; again once it's in, as Sparkle does on the Mac.
Filename: "{app}\conduit-desktop.exe"; Flags: nowait; Check: RelaunchAfterUpdate

[Code]
function RelaunchAfterUpdate: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

// Closing a running Conduit and its conduitd before their files are
// replaced (Setup) or removed (Uninstall). Restart Manager lists what has
// the app's .exe and .dll files open; only the processes whose image is in
// the app's folder are shut down, through a second session that registers
// just them. Windows services and other programs that merely have the files
// open (the antivirus, the Program Compatibility Assistant, Arm's x64
// translation cache) are left alone: registering the files and calling
// RmShutdown, as Inno's CloseApplications does, stops or kills them too.
type
  // RM_UNIQUE_PROCESS: a process id and its start time (FILETIME).
  TRmUniqueProcess = record
    ProcessId: DWORD;
    StartTimeLow: DWORD;
    StartTimeHigh: DWORD;
  end;
  TRmUniqueProcesses = array of TRmUniqueProcess;
  TRmFileTime = record
    Low: DWORD;
    High: DWORD;
  end;

const
  CCH_RM_SESSION_KEY = 32;
  RmForceShutdown = 1;
  ERROR_MORE_DATA = 234;
  // RM_PROCESS_INFO is 668 bytes: RM_UNIQUE_PROCESS its first 12,
  // ApplicationType at byte 652. RmGetList fills a String used as the
  // buffer (2 bytes a character); a process goes back to Restart Manager as
  // a record, since a String passed in stops at its first zero character.
  RmInfoBytes = 668;
  RmNameAt = 12;
  RmNameChars = 256;
  RmTypeAt = 652;
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  SYNCHRONIZE = $100000;
  WAIT_OBJECT_0 = 0;
  ERROR_ACCESS_DENIED = 5;
  // How long each of Conduit's processes may take to end once shut down.
  EndWait = 10000;
  // How many times Conduit is closed and listed again before Setup or
  // Uninstall gives up on it.
  CloseRounds = 3;

function RmStartSession(var SessionHandle: DWORD; SessionFlags: DWORD; SessionKey: String): DWORD;
  external 'RmStartSession@rstrtmgr.dll stdcall delayload';
function RmRegisterFiles(SessionHandle: DWORD; FileCount: Cardinal; FileNames: TArrayOfString;
  ApplicationCount: Cardinal; Applications: Cardinal; ServiceCount: Cardinal; ServiceNames: Cardinal): DWORD;
  external 'RmRegisterResources@rstrtmgr.dll stdcall delayload';
function RmRegisterProcess(SessionHandle: DWORD; FileCount: Cardinal; FileNames: Cardinal;
  ApplicationCount: Cardinal; var Application: TRmUniqueProcess; ServiceCount: Cardinal; ServiceNames: Cardinal): DWORD;
  external 'RmRegisterResources@rstrtmgr.dll stdcall delayload';
function RmGetList(SessionHandle: DWORD; var Needed: Cardinal; var Count: Cardinal; AffectedApps: String;
  var RebootReasons: DWORD): DWORD;
  external 'RmGetList@rstrtmgr.dll stdcall delayload';
function RmShutdown(SessionHandle: DWORD; ActionFlags: DWORD; StatusCallback: Cardinal): DWORD;
  external 'RmShutdown@rstrtmgr.dll stdcall delayload';
function RmEndSession(SessionHandle: DWORD): DWORD;
  external 'RmEndSession@rstrtmgr.dll stdcall delayload';
function OpenProcess(DesiredAccess: DWORD; InheritHandle: BOOL; ProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function QueryFullProcessImageName(Process: THandle; Flags: DWORD; ExeName: String; var Size: DWORD): BOOL;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function GetProcessTimes(Process: THandle; var Created, Exited, Kernel, User: TRmFileTime): BOOL;
  external 'GetProcessTimes@kernel32.dll stdcall';

// The .exe and .dll files under Dir, the uninstaller's own left out.
procedure AddRunnableFiles(const Dir: String; var Files: TArrayOfString);
var
  Found: TFindRec;
  Name: String;
begin
  if not FindFirst(Dir + '\*', Found) then
    Exit;
  try
    repeat
      Name := Found.Name;
      if Found.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
      begin
        if (Name <> '.') and (Name <> '..') then
          AddRunnableFiles(Dir + '\' + Name, Files);
      end
      else if ((CompareText(ExtractFileExt(Name), '.exe') = 0) or
               (CompareText(ExtractFileExt(Name), '.dll') = 0)) and
              (CompareText(Copy(Name, 1, 5), 'unins') <> 0) then
      begin
        SetArrayLength(Files, GetArrayLength(Files) + 1);
        Files[GetArrayLength(Files) - 1] := Dir + '\' + Name;
      end;
    until not FindNext(Found);
  finally
    FindClose(Found);
  end;
end;

// The 32-bit value at byte ByteAt of a String used as a buffer.
function BufferDword(const Buffer: String; ByteAt: Integer): Cardinal;
begin
  Result := Cardinal(Ord(Buffer[ByteAt div 2 + 1])) + (Cardinal(Ord(Buffer[ByteAt div 2 + 2])) shl 16);
end;

// The full path of process Pid's executable; '' when it can't be read.
function ProcessImage(Pid: Cardinal): String;
var
  Process: THandle;
  Size: DWORD;
begin
  Result := '';
  Process := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if Process = 0 then
    Exit;
  try
    Size := 1024;
    SetLength(Result, Size);
    if QueryFullProcessImageName(Process, 0, Result, Size) then
      SetLength(Result, Size)
    else
      Result := '';
  finally
    CloseHandle(Process);
  end;
end;

// Conduit's running processes: the ones that run from the app's folder and
// have its .exe or .dll files open, with Restart Manager's name for each, a
// line each. The other holders are logged and left alone. Their kind
// doesn't decide: to an unelevated Setup, an elevated Conduit is a
// "critical" process Restart Manager can't shut down, and still Conduit.
// False when Restart Manager couldn't list them: then nobody can say
// Conduit isn't running.
function FindRunningApp(var Ours: TRmUniqueProcesses; var Names: String): Boolean;
var
  Session, Status, Reasons: DWORD;
  Needed, Count, Pid, AppType: Cardinal;
  SessionKey, Infos, AppDir, Image, Name: String;
  Files: TArrayOfString;
  I, At, Found, Listed, Tries: Integer;
begin
  Result := False;
  SetArrayLength(Ours, 0);
  Names := '';
  AppDir := ExpandConstant('{app}');
  AddRunnableFiles(AppDir, Files);
  if GetArrayLength(Files) = 0 then
  begin
    Result := True;
    Exit;
  end;
  SessionKey := StringOfChar(' ', CCH_RM_SESSION_KEY + 1);
  Status := RmStartSession(Session, 0, SessionKey);
  if Status <> 0 then
  begin
    Log(Format('Restart Manager: RmStartSession failed (%d)', [Status]));
    Exit;
  end;
  try
    Status := RmRegisterFiles(Session, GetArrayLength(Files), Files, 0, 0, 0, 0);
    if Status <> 0 then
    begin
      Log(Format('Restart Manager: RmRegisterResources failed (%d)', [Status]));
      Exit;
    end;
    Infos := '';
    Count := 0;
    Tries := 0;
    while Status = 0 do
    begin
      Status := RmGetList(Session, Needed, Count, Infos, Reasons);
      Tries := Tries + 1;
      if (Status <> ERROR_MORE_DATA) or (Tries > 3) then
        Break;
      Count := Needed;
      Infos := StringOfChar(#0, Integer(Needed) * (RmInfoBytes div 2));
      Status := 0;
    end;
    if Status <> 0 then
    begin
      Log(Format('Restart Manager: RmGetList failed (%d, %d tries)', [Status, Tries]));
      Exit;
    end;
    Listed := Integer(Count);
    for I := 0 to Listed - 1 do
    begin
      At := I * RmInfoBytes;
      Pid := BufferDword(Infos, At);
      AppType := BufferDword(Infos, At + RmTypeAt);
      Image := ProcessImage(Pid);
      if (Image <> '') and (CompareText(Copy(Image, 1, Length(AppDir) + 1), AddBackslash(AppDir)) = 0) then
      begin
        Found := GetArrayLength(Ours);
        SetArrayLength(Ours, Found + 1);
        Ours[Found].ProcessId := Pid;
        Ours[Found].StartTimeLow := BufferDword(Infos, At + 4);
        Ours[Found].StartTimeHigh := BufferDword(Infos, At + 8);
        Name := Copy(Infos, (At + RmNameAt) div 2 + 1, RmNameChars);
        if Pos(#0, Name) > 0 then
          Name := Copy(Name, 1, Pos(#0, Name) - 1);
        Names := Names + Name + #13#10;
        Log(Format('Restart Manager: pid %d is Conduit''s, %s', [Integer(Pid), Image]));
      end
      else
        Log(Format('Restart Manager: leaving pid %d alone (type %d, %s)', [Integer(Pid), Integer(AppType), Image]));
    end;
    Result := True;
  finally
    RmEndSession(Session);
  end;
end;

// Whether Process has ended, waiting up to Milliseconds for it. Its pid
// running a later-started program counts as ended; a process this can't
// open for lack of access counts as running.
function ProcessEnded(const Process: TRmUniqueProcess; Milliseconds: DWORD): Boolean;
var
  Handle: THandle;
  Created, Exited, Kernel, User: TRmFileTime;
begin
  Handle := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION, False, Process.ProcessId);
  if Handle = 0 then
  begin
    Result := DLLGetLastError <> ERROR_ACCESS_DENIED;
    Exit;
  end;
  try
    Result := False;
    if GetProcessTimes(Handle, Created, Exited, Kernel, User) then
      Result := (Created.Low <> Process.StartTimeLow) or (Created.High <> Process.StartTimeHigh);
    if not Result then
      Result := WaitForSingleObject(Handle, Milliseconds) = WAIT_OBJECT_0;
  finally
    CloseHandle(Handle);
  end;
end;

// Shuts Ours down through a session that registers only them, forced if
// they don't close; True once every one of them has ended. RmShutdown's
// status doesn't say that: it reports success for processes it didn't
// recognise.
function CloseProcesses(const Ours: TRmUniqueProcesses): Boolean;
var
  Session, Status, Reasons: DWORD;
  Needed, Count: Cardinal;
  SessionKey: String;
  Process: TRmUniqueProcess;
  I, Running: Integer;
begin
  Result := True;
  if GetArrayLength(Ours) = 0 then
  begin
    Log('Restart Manager: no Conduit process has the app''s files open');
    Exit;
  end;
  Needed := 0;
  SessionKey := StringOfChar(' ', CCH_RM_SESSION_KEY + 1);
  Status := RmStartSession(Session, 0, SessionKey);
  if Status = 0 then
  try
    for I := 0 to GetArrayLength(Ours) - 1 do
      if Status = 0 then
      begin
        Process := Ours[I];
        Status := RmRegisterProcess(Session, 0, 0, 1, Process, 0, 0);
      end;
    Count := 0;
    if Status = 0 then
      Status := RmGetList(Session, Needed, Count, '', Reasons);
    if Status = ERROR_MORE_DATA then
      Status := 0;
    if Status = 0 then
      Status := RmShutdown(Session, RmForceShutdown, 0);
  finally
    RmEndSession(Session);
  end;
  Running := 0;
  for I := 0 to GetArrayLength(Ours) - 1 do
  begin
    Process := Ours[I];
    if not ProcessEnded(Process, EndWait) then
    begin
      Running := Running + 1;
      Log(Format('Restart Manager: pid %d still runs', [Integer(Process.ProcessId)]));
    end;
  end;
  Result := Running = 0;
  if Result then
    // smoke.ps1 reads this line.
    Log(Format('Restart Manager closed %d Conduit processes: status %d', [GetArrayLength(Ours), Status]))
  else
    Log(Format('Restart Manager: %d of Conduit''s %d processes still run (status %d)', [Running, GetArrayLength(Ours), Status]));
end;

// Closes Ours, then lists Conduit again until a listing finds none running:
// one started meanwhile (a later launch taking the single instance while
// Setup asked) is closed too, under the same consent, at most CloseRounds
// times. False when a close or a listing fails, or Conduit is still there.
function CloseUntilNoneRun(var Ours: TRmUniqueProcesses; var Names: String): Boolean;
var
  Round: Integer;
begin
  Result := False;
  for Round := 1 to CloseRounds do
  begin
    if not CloseProcesses(Ours) then
      Exit;
    if not FindRunningApp(Ours, Names) then
      Exit;
    if GetArrayLength(Ours) = 0 then
    begin
      Result := True;
      Exit;
    end;
    Log(Format('Restart Manager: %d Conduit processes started meanwhile', [GetArrayLength(Ours)]));
  end;
end;

// Run by hand, Setup asks before it closes a running Conduit, in Inno's own
// translated words (its Preparing to Install page's); No stops the install,
// since files in use can't be replaced. A silent install (an update
// WinSparkle runs, once the app agreed to quit) closes it without asking.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Ours: TRmUniqueProcesses;
  Names, Choice: String;
begin
  Result := '';
  // Unlisted, Conduit may be running: files in use can't be replaced.
  if not FindRunningApp(Ours, Names) then
  begin
    Result := SetupMessage(msgErrorCloseApplications);
    Exit;
  end;
  if (GetArrayLength(Ours) > 0) and not WizardSilent then
  begin
    Choice := SetupMessage(msgCloseApplications);
    StringChangeEx(Choice, '&', '', True);
    if SuppressibleMsgBox(SetupMessage(msgApplicationsFound) + #13#10#13#10 + Names + #13#10 + Choice,
         mbConfirmation, MB_YESNO, IDYES) <> IDYES then
    begin
      Log('Restart Manager: Conduit is left running, as asked; Setup stops');
      Result := SetupMessage(msgErrorCloseApplications);
      Exit;
    end;
  end;
  // Files in use can't be replaced.
  if not CloseUntilNoneRun(Ours, Names) then
    Result := SetupMessage(msgErrorCloseApplications);
end;

// Before anything is removed: Conduit is listed and closed, or the uninstall
// stops (Inno's own running-app question: OK tries again, Cancel, as a
// silent uninstall answers, stops it).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Ours: TRmUniqueProcesses;
  Names: String;
begin
  if CurUninstallStep <> usUninstall then
    Exit;
  repeat
    if FindRunningApp(Ours, Names) then
      if CloseUntilNoneRun(Ours, Names) then
        Exit;
  until SuppressibleMsgBox(FmtMessage(SetupMessage(msgUninstallAppRunningError), ['{#AppName}']),
          mbError, MB_OKCANCEL, IDCANCEL) <> IDOK;
  Log('Restart Manager: Conduit may still run; Uninstall stops before removing anything');
  Abort;
end;

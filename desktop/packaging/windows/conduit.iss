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
; Uninstalling removes what this installed: the app's folder, its Start menu
; entry and its registrations. The user's data
; (%LOCALAPPDATA%\Conduit\User Data, its logs, the key in Credential
; Manager) is the app's, never the installer's, and stays.

#if Ver < EncodeVer(6, 3, 0)
  #error Inno Setup 6.3 or later is needed (x64compatible)
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

[Setup]
AppId={{{#AppGuid}}
AppName=Conduit
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
; A running Conduit and its conduitd hold files this replaces: Windows'
; Restart Manager closes both first (conduitd also ends with the app,
; through its job object), forced if they don't close, and the app isn't
; started again (an interactive install offers to launch it at the end).
CloseApplications=force
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
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

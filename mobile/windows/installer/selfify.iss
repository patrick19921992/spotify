; Selfify – Windows-Installer (Inno Setup 6). Baut GitHub Actions, siehe .github/workflows/app.yml.
; Lokal (im Ordner mobile, nach "flutter build windows"):
;   iscc /DAppVersion=1.0.0.1 windows\installer\selfify.iss

#ifndef AppVersion
  #define AppVersion "1.0.0.0"
#endif
#ifndef AppSourceDir
  #define AppSourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef AppOutputDir
  #define AppOutputDir "..\..\build"
#endif

[Setup]
; Feste ID – nie ändern, sonst hält Windows ein Update für eine zweite App.
AppId={{9415849C-E4B2-47C7-89CE-80B2F5F260C0}
AppName=Selfify
AppVersion={#AppVersion}
AppVerName=Selfify {#AppVersion}
AppPublisher=Selfify
VersionInfoVersion={#AppVersion}
; Ohne Admin-Rechte, nur für den angemeldeten Benutzer: landet in %LOCALAPPDATA%\Programs\Selfify
; (so gibt es nie zwei Installationen nebeneinander).
PrivilegesRequired=lowest
DefaultDirName={autopf}\Selfify
; Fester Ordner: [InstallDelete] räumt dort „data“ auf – in einem fremden Ordner wäre das gefährlich
DisableDirPage=yes
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#AppOutputDir}
OutputBaseFilename=selfify-windows-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\selfify.exe
UninstallDisplayName=Selfify
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Läuft Selfify noch, wird es vor dem Update geschlossen.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; selfify.exe, alle DLLs (inkl. VC++-Laufzeit) und der Ordner "data"
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Alte App-Dateien vor einem Update entfernen (Einstellungen und Offline-Musik liegen woanders und bleiben).
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\Selfify"; Filename: "{app}\selfify.exe"
Name: "{autodesktop}\Selfify"; Filename: "{app}\selfify.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\selfify.exe"; Description: "{cm:LaunchProgram,Selfify}"; Flags: nowait postinstall skipifsilent
; Update aus der App (still, /autoupdate=1): Selfify danach von selbst wieder starten
Filename: "{app}\selfify.exe"; Flags: nowait; Check: IsAutoUpdate

[Code]
function IsAutoUpdate: Boolean;
begin
  Result := ExpandConstant('{param:autoupdate|0}') = '1';
end;

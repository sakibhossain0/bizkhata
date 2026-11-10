; Inno Setup script — builds BizKhata-Setup-<version>.exe from the Flutter release folder.
; tool\release_windows.ps1 runs it with the version from pubspec.yaml. By hand:
; 1. flutter build windows --release
; 2. "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\bizkhata.iss

#define AppName "BizKhata"
#ifndef AppVersion
  #define AppVersion "1.2.0"
#endif
#define AppPublisher "BizKhata"
#define AppExe "bizkhata.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6C080DB1-A9EA-43F5-A6E2-8EA04B477579}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=BizKhata-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user install works without admin rights on shop PCs.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Business data lives in %APPDATA% and is intentionally NOT removed on uninstall.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef OutputDir
  #define OutputDir "dist"
#endif

[Setup]
AppId={{EF861A70-83CE-4D4A-91B2-D4B77B00A18D}
AppName=KNX home
AppVersion={#AppVersion}
AppPublisher=Juanelas
DefaultDirName={autopf}\KNX home
DefaultGroupName=KNX home
UninstallDisplayIcon={app}\knx_home.exe
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
OutputDir={#OutputDir}
OutputBaseFilename=knx-home-windows-{#AppVersion}-setup
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\KNX home"; Filename: "{app}\knx_home.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\KNX home"; Filename: "{app}\knx_home.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\knx_home.exe"; Description: "Launch KNX home"; Flags: postinstall nowait skipifsilent

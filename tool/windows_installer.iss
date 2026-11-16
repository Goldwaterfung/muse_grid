#ifndef AppVersion
  #error AppVersion must be supplied on the ISCC command line.
#endif
#ifndef BuildDirectory
  #error BuildDirectory must be supplied on the ISCC command line.
#endif
#ifndef OutputDirectory
  #error OutputDirectory must be supplied on the ISCC command line.
#endif
#ifndef IconPath
  #error IconPath must be supplied on the ISCC command line.
#endif

#define AppName "MuseGrid"
#define AppExecutable "muse_grid.exe"

[Setup]
AppId={{D68ECC4F-1582-46D8-9E65-A19242CD29EB}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=MuseGrid
DefaultDirName={autopf}\MuseGrid
DefaultGroupName=MuseGrid
UninstallDisplayIcon={app}\{#AppExecutable}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir={#OutputDirectory}
OutputBaseFilename=muse-grid-windows-{#AppVersion}-setup
SetupIconFile={#IconPath}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#BuildDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MuseGrid"; Filename: "{app}\{#AppExecutable}"
Name: "{autodesktop}\MuseGrid"; Filename: "{app}\{#AppExecutable}"; Tasks: desktopicon

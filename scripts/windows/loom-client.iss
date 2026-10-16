#ifndef SourceDir
  #error SourceDir must point to the Flutter Windows Release directory.
#endif
#ifndef ArtifactDir
  #error ArtifactDir must point to the engineering artifact directory.
#endif
#ifndef AppVersion
  #error AppVersion must be supplied from apps/loom/pubspec.yaml.
#endif
#ifndef VersionInfoVersion
  #error VersionInfoVersion must be supplied from apps/loom/pubspec.yaml.
#endif

[Setup]
AppId={{75199756-FB4E-4E0F-9DE5-794EB3014EB6}
AppName=Loom
AppVersion={#AppVersion}
AppPublisher=0800x
AppPublisherURL=https://github.com/0800x/Loom
AppSupportURL=https://github.com/0800x/Loom/issues
AppUpdatesURL=https://github.com/0800x/Loom
DefaultDirName={localappdata}\Programs\Loom
DefaultGroupName=Loom
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#ArtifactDir}
OutputBaseFilename=loom-windows-x64-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\loom.exe
VersionInfoVersion={#VersionInfoVersion}
VersionInfoCompany=0800x
VersionInfoDescription=Loom Windows engineering installer
VersionInfoProductName=Loom
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Loom"; Filename: "{app}\loom.exe"
Name: "{autodesktop}\Loom"; Filename: "{app}\loom.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\loom.exe"; Description: "Launch Loom"; Flags: nowait postinstall skipifsilent

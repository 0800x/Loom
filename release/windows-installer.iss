#ifndef ReleaseVersion
  #error ReleaseVersion is required
#endif
[Setup]
AppId={{6637C8B7-4B84-4A4D-AE9D-C7E1D617916C}
AppName=Loom
AppVersion={#ReleaseVersion}
VersionInfoVersion=0.1.0.28
AppPublisher=Loom contributors
DefaultDirName={localappdata}\Programs\Loom
DefaultGroupName=Loom
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Loom-{#ReleaseVersion}-windows-x64-installer-unsigned-engineering
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\loom.exe
[Files]
Source: "..\apps\loom\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Loom"; Filename: "{app}\loom.exe"

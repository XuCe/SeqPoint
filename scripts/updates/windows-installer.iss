#ifndef MyAppVersion
  #error MyAppVersion is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif

[Setup]
AppId={{38BCE0C0-B936-4B3F-819A-C5AA22C776AF}
AppName=序点 SeqPoint
AppVersion={#MyAppVersion}
AppPublisher=XuCe
DefaultDirName={localappdata}\Programs\SeqPoint
DefaultGroupName=序点 SeqPoint
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\seqpoint_app.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
CloseApplicationsFilter=seqpoint_app.exe
RestartApplications=no
UsePreviousAppDir=yes
DisableProgramGroupPage=yes

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\序点 SeqPoint"; Filename: "{app}\seqpoint_app.exe"
Name: "{autodesktop}\序点 SeqPoint"; Filename: "{app}\seqpoint_app.exe"

[Run]
Filename: "{app}\seqpoint_app.exe"; Description: "启动序点"; Flags: nowait postinstall

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  WaitCount: Integer;
begin
  WaitCount := 0;
  while CheckForMutexes('Local\SeqPointUpdateRunning') and (WaitCount < 1200) do
  begin
    Sleep(100);
    WaitCount := WaitCount + 1;
  end;
  if CheckForMutexes('Local\SeqPointUpdateRunning') then
    Result := '序点尚未安全退出。请保存并关闭便签后重试更新。'
  else
    Result := '';
end;

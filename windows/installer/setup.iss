; Inno Setup script for Home Radio (Windows). Built by
; windows/scripts/build-installer.ps1, in CI by .github/workflows/release.yml.
;
; The in-app updater (lib/data/services/update_service.dart) runs the setup
; with /SILENT /SUPPRESSMSGBOXES /NORESTART and quits; the setup closes any
; running instance, replaces the files and starts the app again (the [Run]
; entry deliberately has no skipifsilent).

#ifndef PublishDir
  #define PublishDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Home Radio"
#define AppPublisher "jaycloud"
#define AppExeName "home_radio.exe"
#define AppId "{{48294707-83FF-4493-B528-3BF21CBCDED4}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\Home Radio
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=.\output
OutputBaseFilename=setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=force
RestartApplications=no
WizardStyle=modern

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Without the VC++ runtime the app dies in MSVCP140.dll on fresh Windows.
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; Check: VCRedistNeedsInstall; StatusMsg: "Visual C++ Laufzeit wird installiert..."; Flags: waituntilterminated
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall

[Code]
function VCRedistNeedsInstall: Boolean;
var
  Installed: Cardinal;
begin
  Result := not (RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64', 'Installed', Installed) and (Installed = 1));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  // The Restart Manager doesn't reliably close the app - make sure.
  if CurStep = ssInstall then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

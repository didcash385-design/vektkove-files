#define Architecture GetEnv("VK_ARCH")
#define SourceDir GetEnv("VK_SOURCE_DIR")
#define OutputDir GetEnv("VK_OUTPUT_DIR")
#define Version GetEnv("VK_VERSION")
#if Version == ""
#define Version "1.4.4"
#endif

[Setup]
AppId={{B1A2E71E-A721-464E-9F46-B7C9B72B6211}
AppName=Vektkove
AppVersion={#Version}
AppPublisher=VCCcash
DefaultDirName={localappdata}\Programs\Vektkove
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=vektkove-{#Version}-windows-{#Architecture}-setup
Compression=lzma2
SolidCompression=yes
ChangesEnvironment=yes
UninstallDisplayIcon={app}\vk.exe
#if Architecture == "arm64"
ArchitecturesAllowed=arm64
#else
ArchitecturesAllowed=x64compatible
#endif

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
function EditPath(const OriginalPath, Directory: String; RemoveDirectory: Boolean): String;
var
  Remaining, Entry: String;
  Separator: Integer;
  Found, HasEntry: Boolean;
begin
  Result := '';
  Remaining := OriginalPath;
  Found := False;
  HasEntry := False;
  if Remaining = '' then begin
    if not RemoveDirectory then Result := Directory;
    Exit;
  end;
  while True do begin
    Separator := Pos(';', Remaining);
    if Separator = 0 then begin
      Entry := Remaining;
      Remaining := '';
    end else begin
      Entry := Copy(Remaining, 1, Separator - 1);
      Delete(Remaining, 1, Separator);
    end;
    if CompareText(RemoveBackslashUnlessRoot(Trim(Entry)), RemoveBackslashUnlessRoot(Directory)) = 0 then begin
      Found := True;
    end else if RemoveDirectory then begin
      if HasEntry then Result := Result + ';';
      Result := Result + Entry;
      HasEntry := True;
    end;
    if Separator = 0 then Break;
  end;
  if not RemoveDirectory then begin
    Result := OriginalPath;
    if not Found then Result := Result + ';' + Directory;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  OldPath, NewPath: String;
begin
  if CurStep <> ssPostInstall then Exit;
  RegQueryStringValue(HKCU, 'Environment', 'Path', OldPath);
  NewPath := EditPath(OldPath, ExpandConstant('{app}'), False);
  if NewPath <> OldPath then begin
    if not RegWriteExpandStringValue(HKCU, 'Environment', 'Path', NewPath) then
      RaiseException('Could not update the user PATH.');
    if not RegWriteDWordValue(HKCU, 'Software\VCCcash\Vektkove', 'PathAdded', 1) then
      RaiseException('Could not record the user PATH change.');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  OldPath: String;
  PathAdded: Cardinal;
begin
  if CurUninstallStep <> usUninstall then Exit;
  if RegQueryDWordValue(HKCU, 'Software\VCCcash\Vektkove', 'PathAdded', PathAdded) and (PathAdded = 1) then begin
    if RegQueryStringValue(HKCU, 'Environment', 'Path', OldPath) then
      RegWriteExpandStringValue(HKCU, 'Environment', 'Path', EditPath(OldPath, ExpandConstant('{app}'), True));
    RegDeleteValue(HKCU, 'Software\VCCcash\Vektkove', 'PathAdded');
  end;
end;
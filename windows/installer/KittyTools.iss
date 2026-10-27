; Kitty Tools 的安装程序（Inno Setup 7，PLAN-setup-inno）。build-release.ps1 调：
;   ISCC /DAppVersion=0.1.0 /DArch=x64 /DSourceDir=<发布目录> /O<输出目录> installer\KittyTools.iss
; 自检（tools/setup-e2e.ps1）再加 /DTestKey=<字母数字>：AppId、开机启动值、快捷方式、互斥量都换成测试名
; （和 Core/SetupRules.NamesFor 一一对应），装的程序配 KITTY_PROBE_PROFILE=<同一个名字> 跑，不碰真的那一份。
; 这个文件要存成带 BOM 的 UTF-8，不然 ISCC 按 ANSI 读，中文会乱。
; 命令行参数（静默安装 / 自检用）：/AUTOSTART=0 不写开机启动；卸载时 /REMOVEDATA=1 连数据一起挪进回收站。

#ifndef AppVersion
  #error 要传 /DAppVersion=x.y.z
#endif
#ifndef Arch
  #error 要传 /DArch=x64 或 /DArch=arm64
#endif
#ifndef SourceDir
  #error 要传 /DSourceDir=<发布目录>
#endif

#ifndef TestKey
  ; AppId 永远不改（PLAN-setup-inno I2）：「设置 › 应用」里的登记、更新时找原来装在哪都靠它。
  #define AppIdValue "{{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}"
  #define UninstallKeyName "{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}_is1"
  #define RunValue "KittyTools"
  #define ShortcutName "Kitty Tools"
  #define MutexName "Local\KittyTools"
  #define OutputSuffix ""
#else
  #define AppIdValue "KittyTools.Test." + TestKey
  #define UninstallKeyName "KittyTools.Test." + TestKey + "_is1"
  #define RunValue "KittyTools.Probe." + TestKey
  #define ShortcutName "Kitty Tools.Test." + TestKey
  #define MutexName "Local\KittyTools.Probe." + TestKey
  #define OutputSuffix "-test-" + TestKey
#endif

[Setup]
AppId={#AppIdValue}
AppName=Kitty Tools
AppVersion={#AppVersion}
AppVerName=Kitty Tools {#AppVersion}
AppPublisher=YyAdnBug
AppPublisherURL=https://github.com/YyAdnBug/kitty-tools
AppSupportURL=https://github.com/YyAdnBug/kitty-tools/issues
DefaultDirName={autopf}\Kitty Tools
AppendDefaultDirName=yes
UsePreviousAppDir=yes
PrivilegesRequired=lowest
DisableWelcomePage=yes
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableReadyPage=yes
ShowLanguageDialog=no
; 不让「重新启动管理器」去强关：强关会丢掉剪贴板里还没提交的删除。程序开着时先 --quit（PrepareToInstall）。
CloseApplications=no
RestartApplications=no
WizardStyle=modern dynamic windows11
WizardImageFile=wizard-large-*.png
WizardSmallImageFile=wizard-small-*.png
SetupIconFile=..\KittyTools\Resources\AppIcon.ico
UninstallDisplayIcon={app}\KittyTools.exe
UninstallDisplayName=Kitty Tools
OutputBaseFilename=KittyTools-{#AppVersion}-windows-{#Arch}-setup{#OutputSuffix}
Compression=lzma2/max
SolidCompression=yes
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
; 和 zip 里的一模一样（build-release.ps1 打 zip 的那个目录）。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 和 App/StartMenuShortcut.cs 同一个位置、同一个名字：App 第一次运行时看到它已经在，就不再建。
Name: "{userprograms}\{#ShortcutName}"; Filename: "{app}\KittyTools.exe"; Comment: "Kitty Tools"

[Registry]
; 和 App/Autostart.cs 写的一字不差。更新时不动（照用户在程序里改过的）。
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#RunValue}"; \
  ValueData: """{app}\KittyTools.exe"""; Flags: uninsdeletevalue; Check: ShouldWriteAutostart

[Run]
Filename: "{app}\KittyTools.exe"; Description: "现在打开 Kitty Tools"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
; 程序内更新带进来的新文件 Inno 不认得，整个文件夹删；WhyNotInstallDir 保证了这个文件夹整个是我们的（名字是 Kitty Tools）。
Type: filesandordirs; Name: "{app}"

[Code]
var
  AutostartBox: TNewCheckBox;
  InstalledVersion: String;

{ ---------- 版本 ---------- }

function VersionPart(var S: String): Integer;
var
  P: Integer;
begin
  P := Pos('.', S);
  if P = 0 then
  begin
    Result := StrToIntDef(S, 0);
    S := '';
  end
  else
  begin
    Result := StrToIntDef(Copy(S, 1, P - 1), 0);
    Delete(S, 1, P);
  end;
end;

{ A 比 B 新返回 1，一样返回 0，更旧返回 -1（只看数字段，最多四段）。 }
function CompareVersions(A, B: String): Integer;
var
  I, X, Y: Integer;
begin
  Result := 0;
  for I := 1 to 4 do
  begin
    X := VersionPart(A);
    Y := VersionPart(B);
    if X <> Y then
    begin
      if X > Y then
        Result := 1
      else
        Result := -1;
      exit;
    end;
  end;
end;

function IsUpdate: Boolean;
begin
  Result := InstalledVersion <> '';
end;

{ ---------- 程序开着时叫它退出（PLAN-setup-inno I8，不按进程名结束） ---------- }

function AppRunning: Boolean;
begin
  Result := CheckForMutexes('{#MutexName}');
end;

function AskAppToQuit(const Exe: String): Boolean;
var
  Code, I: Integer;
begin
  Result := not AppRunning;
  if Result then
    exit;
  if FileExists(Exe) then
    Exec(Exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  for I := 1 to 50 do
  begin
    if not AppRunning then
    begin
      Result := True;
      exit;
    end;
    Sleep(200);
  end;
end;

{ ---------- 装到哪（PLAN-setup-inno I6，照旧方案 §2.2） ---------- }

function WithKittyFolder(const Dir: String): String;
begin
  Result := RemoveBackslashUnlessRoot(Trim(Dir));
  if CompareText(ExtractFileName(Result), 'Kitty Tools') <> 0 then
    Result := AddBackslash(Result) + 'Kitty Tools';
end;

function IsSameOrUnder(const Dir, Parent: String): Boolean;
var
  Root: String;
begin
  Result := False;
  if Parent = '' then
    exit;
  Root := RemoveBackslashUnlessRoot(Parent);
  Result := (CompareText(Dir, Root) = 0) or (Pos(Lowercase(AddBackslash(Root)), Lowercase(Dir)) = 1);
end;

function CanWrite(const Dir: String): Boolean;
var
  Existed: Boolean;
  Probe: String;
begin
  Existed := DirExists(Dir);
  Result := ForceDirectories(Dir);
  if not Result then
    exit;
  Probe := AddBackslash(Dir) + '.kitty-write-test';
  Result := SaveStringToFile(Probe, 'x', False);
  DeleteFile(Probe);
  if not Existed then
    RemoveDir(Dir);
end;

{ 能用返回空串，否则是给用户看的原因。Dir 已经拼过「Kitty Tools」。 }
function WhyNotInstallDir(const Dir: String): String;
begin
  Result := '';
  if (Length(Dir) < 4) or (Copy(Dir, 2, 2) <> ':\') then
    Result := '请选这台电脑磁盘上的文件夹。'
  else if IsSameOrUnder(Dir, ExpandConstant('{win}')) or IsSameOrUnder(Dir, ExpandConstant('{commonpf32}')) or
    IsSameOrUnder(Dir, ExpandConstant('{commonpf64}')) or IsSameOrUnder(Dir, ExpandConstant('{%ProgramFiles(Arm)|}')) then
    Result := '不能装在 Windows 或 Program Files 里（以后更新要管理员权限）。换一个位置，比如默认的那个。'
  else if Length(Dir) > 200 then
    Result := '这个位置的路径太长，请选一个浅一点的文件夹。'
  else if not CanWrite(Dir) then
    Result := '这个文件夹写不进去，换一个位置。';
end;

{ ---------- 安装 ---------- }

function InitializeSetup: Boolean;
begin
  Result := True;
  if not RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#UninstallKeyName}',
    'DisplayVersion', InstalledVersion) then
    InstalledVersion := '';
  { 一样或更旧的版本：问一句（PLAN-setup-inno I7）；静默时照装。 }
  if IsUpdate and (CompareVersions(InstalledVersion, '{#AppVersion}') >= 0) and (not WizardSilent) then
    Result := MsgBox('已经装了 Kitty Tools ' + InstalledVersion + '，要重新安装吗？',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

procedure InitializeWizard;
begin
  { 选位置那一页下面加「开机时自动打开」（PLAN-setup-inno I4），默认勾上，和程序里 StartWithWindows 的默认值一样。 }
  AutostartBox := TNewCheckBox.Create(WizardForm);
  AutostartBox.Parent := WizardForm.SelectDirPage;
  AutostartBox.Left := WizardForm.DirEdit.Left;
  AutostartBox.Top := WizardForm.DirEdit.Top + WizardForm.DirEdit.Height + ScaleY(20);
  AutostartBox.Width := WizardForm.SelectDirPage.ClientWidth - AutostartBox.Left;
  AutostartBox.Height := ScaleY(20);
  AutostartBox.Caption := '开机时自动打开';
  AutostartBox.Checked := ExpandConstant('{param:autostart|1}') <> '0';
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectDir then
    WizardForm.NextButton.Caption := '安装'
  else if (CurPageID = wpReady) and IsUpdate then
    WizardForm.NextButton.Caption := '更新到 {#AppVersion}';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Dir, Why: String;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    exit;
  { 手打的路径不经过 AppendDefaultDirName，这里补上「Kitty Tools」。 }
  Dir := WithKittyFolder(WizardDirValue);
  WizardForm.DirEdit.Text := Dir;
  Why := WhyNotInstallDir(Dir);
  if Why <> '' then
  begin
    MsgBox(Why, mbError, MB_OK);
    Result := False;
  end;
end;

function ShouldWriteAutostart: Boolean;
begin
  Result := (not IsUpdate) and AutostartBox.Checked;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { 静默安装不走 NextButtonClick，位置在这里再查一遍。 }
  Result := WhyNotInstallDir(WithKittyFolder(WizardDirValue));
  if Result <> '' then
    exit;
  if not AskAppToQuit(ExpandConstant('{app}\KittyTools.exe')) then
    Result := 'Kitty Tools 还开着。请从托盘菜单退出它，再运行一次安装程序。';
end;

{ ---------- 卸载（PLAN-setup-inno I10） ---------- }

function InitializeUninstall: Boolean;
begin
  Result := AskAppToQuit(ExpandConstant('{app}\KittyTools.exe'));
  if (not Result) and (not UninstallSilent) then
    MsgBox('Kitty Tools 还开着。请从托盘菜单退出它，再卸载。', mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  RemoveData: Boolean;
  Params: String;
  Code: Integer;
begin
  if CurUninstallStep <> usUninstall then
    exit;
  { 默认不删数据；静默卸载时只认 /REMOVEDATA=1。 }
  RemoveData := ExpandConstant('{param:removedata|0}') = '1';
  if (not RemoveData) and (not UninstallSilent) then
    RemoveData := MsgBox('要同时删除你的数据吗？' + #13#10 + #13#10 +
      '剪贴板历史、设置、截图历史会挪进回收站。选「否」就留着，以后重装还能接着用。',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
  { 密钥、开机启动（程序里后来打开的那种 Inno 不知道），要的话数据目录：交给程序自己删，它知道名字。 }
  Params := '--uninstall-cleanup';
  if RemoveData then
    Params := Params + ' --remove-data';
  Exec(ExpandConstant('{app}\KittyTools.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, Code);
  Log('uninstall-cleanup exit=' + IntToStr(Code));
end;

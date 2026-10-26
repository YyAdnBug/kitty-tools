// 安装流程（PLAN-setup S3–S8）：先校验载荷（坏了什么都不写）→ 读「设置 › 应用」里原来的登记（S4）→ 第一页（位置、开机启动）
// 或「重新安装？」→ 让开着的程序退出（S5）→ 载荷解压到同卷的临时文件夹 → UpdateInstaller.Install 换进去（失败回滚，S6）→
// .kitty-install、Uninstall.exe、登记、开始菜单、开机启动（S7）→ 完成页（现在打开）。
// 界面版和 --quiet 走同一个 Work：界面版放到后台线程，进度页每 200 ms 看一眼做到哪了。
using System.IO.Compression;
using System.Text;
using KittyTools.Core;

namespace KittyTools.Setup;

internal sealed class Installer
{
    private const int IdInstall = 100;
    private const int IdChangeDir = 101;
    private const int IdRetry = 102;
    private const int IdFinish = 103;

    private readonly string _exe;
    private readonly SetupTrailer _trailer;
    private readonly SetupNames _names;
    private readonly string _version;

    /// <summary>已经装过（S4）：位置不能改，也不碰开机启动（用户可能在程序里关掉了）。</summary>
    private readonly bool _update;

    private string _dir;
    private bool _autostart;
    private int _exitCode = ExitCodes.Cancelled;

    // 后台线程写、界面线程读。
    private volatile int _percent;
    private volatile Outcome _outcome;
    private volatile string? _error;

    private Installer(string exe, SetupTrailer trailer, SetupNames names, string version, bool update, string dir, bool autostart)
    {
        _exe = exe;
        _trailer = trailer;
        _names = names;
        _version = version;
        _update = update;
        _dir = dir;
        _autostart = autostart;
    }

    private enum Outcome
    {
        Working,
        Done,
        AppRunning,
        Failed,
    }

    private string InstalledExe => Path.Combine(_dir, SetupRules.ExeName);

    public static int Run(string exe, SetupTrailer trailer, SetupArgs args, SetupNames names)
    {
        Uninstaller.CleanStaleCopies(null);
        var version = typeof(Installer).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
        bool intact;
        using (var file = File.OpenRead(exe))
        {
            intact = SetupPayload.Verify(file, trailer);
        }

        if (!intact)
        {
            SetupLog.Write("install.payload-corrupt");
            if (!args.Quiet)
            {
                SetupUi.ShowError("安装包损坏了", "校验没通过，什么都没装。请重新下载 Kitty Tools 的安装包。");
            }

            return ExitCodes.BadPackage;
        }

        // S4：「设置 › 应用」里登记过、那个文件夹里程序还在，就是更新；用 zip 解压的旧版不认，当新装。
        var (registeredDir, registeredVersion) = SystemSteps.ReadRegistration(names);
        var existing = registeredDir is not null && File.Exists(Path.Combine(registeredDir, SetupRules.ExeName))
            ? SetupRules.Normalize(registeredDir)
            : null;
        var dir = existing ?? (args.Dir is { Length: > 0 } chosen
            ? SetupRules.ResolveInstallDir(Path.GetFullPath(chosen))
            : DefaultDir(names));
        if (existing is not null && args.Dir is not null)
        {
            SetupLog.Write("install.dir-ignored (already installed)");
        }

        SetupLog.Write($"install.plan version={version} update={existing is not null} installed={registeredVersion ?? "-"}");
        var installer = new Installer(exe, trailer, names, version, existing is not null, dir, !args.NoAutostart);
        var code = args.Quiet ? installer.RunQuiet(!args.NoLaunch) : installer.RunInteractive(registeredVersion);
        if (code != ExitCodes.Ok && !installer._update)
        {
            // 新装没成：Check 建的空文件夹收掉。
            SystemSteps.RemoveIfEmpty(installer._dir);
        }

        SetupLog.Write($"install.exit {code}");
        return code;
    }

    /// <summary>默认 %LOCALAPPDATA%\Programs\Kitty Tools；测试名下放到 %TEMP%，不碰真实的位置。</summary>
    private static string DefaultDir(SetupNames names)
        => names.ProbeProfile is { } profile
            ? Path.Combine(Path.GetTempPath(), "KittyTools.Test." + profile, SetupRules.FolderName)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", SetupRules.FolderName);

    private int RunQuiet(bool launch)
    {
        if (Check() is { } problem)
        {
            SetupLog.Write($"install.bad-dir {problem}");
            return ExitCodes.BadDirectory;
        }

        Work();
        switch (_outcome)
        {
            case Outcome.Done:
                if (launch)
                {
                    SystemSteps.Launch(_names, InstalledExe);
                }

                return ExitCodes.Ok;
            case Outcome.AppRunning:
                return ExitCodes.AppRunning;
            default:
                return ExitCodes.Error;
        }
    }

    private int RunInteractive(string? registeredVersion)
    {
        var first = _update && SetupRules.IsSameOrOlder(_version, registeredVersion)
            ? ReinstallPage(registeredVersion!)
            : WelcomePage();
        return SetupUi.Run(first) ? _exitCode : ExitCodes.Error;
    }

    /// <summary>位置能不能用：§2.2 的规则（新装才看）、建得出文件夹、写得进去。能用返回 null，否则是给用户看的原因。</summary>
    private string? Check()
    {
        if (!_update && SetupRules.WhyNotInstallDir(_dir, SystemSteps.Folders()) is { } why)
        {
            return why;
        }

        try
        {
            Directory.CreateDirectory(_dir);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            SetupLog.Write($"install.mkdir-failed {ex.GetType().Name}");
            return "这个位置建不了文件夹，请换一个。";
        }

        return UpdateInstaller.CanWriteInstallDirectory(_dir)
            ? null
            : _update
                ? "原来装的位置现在写不进去（可能被挪到了需要管理员权限的地方）。请先卸载，再重新安装。"
                : "这个位置没有写入权限，请换一个（比如 D 盘下面的文件夹）。";
    }

    private Page WelcomePage() => new()
    {
        Instruction = _update ? $"把 Kitty Tools 更新到 {_version}" : $"安装 Kitty Tools {_version}",
        Content = _update ? $"装在：{_dir}\n设置和数据都会保留。" : $"装到：{_dir}",
        Buttons = _update
            ? [(IdInstall, $"更新到 {_version}"), (SetupUi.IdCancel, "取消")]
            : [(IdInstall, "安装"), (IdChangeDir, "换个位置…"), (SetupUi.IdCancel, "取消")],
        DefaultButton = IdInstall,
        Checkbox = _update ? null : "开机时自动打开",
        Checked = !_update && _autostart,
        Clicked = OnWelcome,
    };

    private Page ReinstallPage(string installed) => new()
    {
        Instruction = $"已经装了 Kitty Tools {installed}",
        Content = $"这个安装包是 {_version}，要重新安装吗？设置和数据都会保留。\n装在：{_dir}",
        Buttons = [(IdInstall, "重新安装"), (SetupUi.IdCancel, "取消")],
        DefaultButton = IdInstall,
        Clicked = OnWelcome,
    };

    private bool OnWelcome(int button, bool isChecked)
    {
        if (!_update)
        {
            _autostart = isChecked;
        }

        switch (button)
        {
            case IdChangeDir:
                if (SetupUi.PickFolder(Path.GetDirectoryName(_dir)) is { } picked)
                {
                    var dir = SetupRules.ResolveInstallDir(picked);
                    if (SetupRules.WhyNotInstallDir(dir, SystemSteps.Folders()) is { } why)
                    {
                        SetupUi.Warn("不能装在这里", why);
                    }
                    else
                    {
                        _dir = dir;
                        SetupUi.Navigate(WelcomePage());
                    }
                }

                return true;
            case IdInstall:
                if (Check() is { } problem)
                {
                    SetupUi.Warn("不能装在这里", problem);
                    return true;
                }

                StartWork();
                return true;
            default:
                return false;
        }
    }

    private void StartWork()
    {
        _percent = 0;
        _error = null;
        _outcome = Outcome.Working;
        SetupUi.Navigate(new Page
        {
            Instruction = _update ? $"正在更新到 {_version}…" : "正在安装…",
            Content = _dir,
            Progress = true,
            Buttons = [(SetupUi.IdCancel, "取消")],
            Tick = OnTick,
        });
        var thread = new Thread(() =>
        {
            SystemSteps.InitializeCom();
            Work();
        })
        {
            IsBackground = true,
            Name = "KittyTools.Setup.Install",
        };
        thread.Start();
    }

    private void OnTick()
    {
        SetupUi.SetProgress(_percent);
        switch (_outcome)
        {
            case Outcome.Done:
                SetupUi.Navigate(DonePage());
                break;
            case Outcome.AppRunning:
                SetupUi.Navigate(AppRunningPage());
                break;
            case Outcome.Failed:
                SetupUi.Navigate(FailedPage());
                break;
        }
    }

    private Page DonePage() => new()
    {
        Instruction = _update ? $"已更新到 {_version}" : "装好了",
        Content = $"装在：{_dir}\n开始菜单里能找到 Kitty Tools，从「设置 › 应用」可以卸载。",
        Buttons = [(IdFinish, "完成")],
        DefaultButton = IdFinish,
        Checkbox = "现在打开",
        Checked = true,
        Clicked = (button, launch) =>
        {
            _exitCode = ExitCodes.Ok;
            if (button == IdFinish && launch)
            {
                SystemSteps.Launch(_names, InstalledExe);
            }

            return false;
        },
    };

    private Page AppRunningPage() => new()
    {
        Instruction = "Kitty Tools 还开着",
        Content = "请从托盘退出 Kitty Tools 后点重试。",
        Icon = PageIcon.Warning,
        Buttons = [(IdRetry, "重试"), (SetupUi.IdCancel, "取消")],
        DefaultButton = IdRetry,
        Clicked = (button, _) =>
        {
            if (button == IdRetry)
            {
                StartWork();
                return true;
            }

            _exitCode = ExitCodes.AppRunning;
            return false;
        },
    };

    private Page FailedPage() => new()
    {
        Instruction = _update ? "没能更新" : "没装上",
        Content = _error,
        Icon = PageIcon.Error,
        Buttons = [(SetupUi.IdCancel, "关闭")],
        Clicked = (_, _) =>
        {
            _exitCode = ExitCodes.Error;
            return false;
        },
    };

    /// <summary>真正干活，结果写进 _outcome / _error。不碰界面。</summary>
    private void Work()
    {
        string? staging = null;
        try
        {
            if (!SystemSteps.QuitRunningApp(_names))
            {
                Finish(Outcome.AppRunning, null);
                return;
            }

            _percent = 10;
            staging = Extract();
            var entry = UpdateInstaller.FindEntryDirectory(staging, SetupRules.ExeName)
                        ?? throw new SetupException("安装包里没有 KittyTools.exe，请重新下载。");
            Directory.CreateDirectory(_dir);
            var result = UpdateInstaller.Install(entry, _dir);
            if (!result.Ok)
            {
                SetupLog.Write($"install.copy-failed {result.Error}");
                throw new SetupException(
                    _update ? "换文件时出错，已经恢复成原来的版本。可能有文件被别的程序占着，稍后再试。" : "复制文件时出错，已经撤回。可能有文件被别的程序占着，稍后再试。");
            }

            _percent = 75;
            UpdateInstaller.RemoveOldFiles(_dir);
            WriteMarker(Directory.EnumerateFiles(entry, "*", SearchOption.AllDirectories)
                .Select(file => Path.GetRelativePath(entry, file)));
            WriteUninstaller();
            _percent = 85;
            SystemSteps.Register(_names, _dir, _version);
            SystemSteps.CreateShortcut(_names, InstalledExe);
            if (!_update)
            {
                SystemSteps.SetAutostart(_names, InstalledExe, _autostart);
            }

            _percent = 100;
            SetupLog.Write($"install.done files={result.Installed.Count}");
            Finish(Outcome.Done, null);
        }
        catch (Exception ex)
        {
            SetupLog.Write($"install.failed {ex.GetType().Name} {ex.Message}");
            Finish(Outcome.Failed, ex is SetupException ? ex.Message : $"安装时出错，详情在日志里：{SetupLog.Path}");
        }
        finally
        {
            if (staging is not null)
            {
                SystemSteps.DeleteDirectory(staging);
            }
        }
    }

    private void Finish(Outcome outcome, string? error)
    {
        _error = error;
        _outcome = outcome;
    }

    /// <summary>载荷解压到安装目录旁边（同一个卷）；那里建不了就用 %TEMP%。进度 10 → 60。</summary>
    private string Extract()
    {
        var staging = StagingDir();
        using var file = File.OpenRead(_exe);
        using var archive = new ZipArchive(SetupPayload.OpenPayload(file, _trailer), ZipArchiveMode.Read);
        var root = Path.GetFullPath(staging) + Path.DirectorySeparatorChar;
        var total = Math.Max(1, archive.Entries.Count);
        var done = 0;
        foreach (var item in archive.Entries)
        {
            var target = Path.GetFullPath(Path.Combine(staging, item.FullName));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupException("安装包里有不该有的路径，请重新下载。");
            }

            if (item.Name.Length == 0)
            {
                Directory.CreateDirectory(target);
            }
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                item.ExtractToFile(target, overwrite: true);
            }

            done++;
            _percent = 10 + (50 * done / total);
        }

        return staging;
    }

    private string StagingDir()
    {
        var name = ".KittyTools-setup-" + Guid.NewGuid().ToString("N");
        if (Path.GetDirectoryName(_dir) is { } parent)
        {
            try
            {
                return Directory.CreateDirectory(Path.Combine(parent, name)).FullName;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                SetupLog.Write($"install.staging-fallback {ex.GetType().Name}");
            }
        }

        return Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), name)).FullName;
    }

    /// <summary>.kitty-install：这次装的文件并上上次记的（更新后旧版本留下的文件卸载时也认得）。</summary>
    private void WriteMarker(IEnumerable<string> files)
    {
        var previous = SetupRules.ReadMarker(_dir)?.Files ?? Array.Empty<string>();
        var marker = new SetupMarker(
            _dir,
            _version,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            files.Union(previous, StringComparer.OrdinalIgnoreCase).ToList());
        File.WriteAllText(Path.Combine(_dir, SetupRules.MarkerName), SetupRules.WriteMarker(marker), new UTF8Encoding(false));
    }

    /// <summary>安装程序本体（载荷起点之前那段）复制成 Uninstall.exe。旧的被占着（有人正在卸载）就先改名让开。</summary>
    private void WriteUninstaller()
    {
        var target = Path.Combine(_dir, SetupRules.UninstallerName);
        var partial = target + ".partial";
        using (var file = File.OpenRead(_exe))
        using (var output = File.Create(partial))
        {
            SetupPayload.CopyPrefix(file, _trailer.PayloadOffset, output);
        }

        try
        {
            File.Move(partial, target, overwrite: true);
        }
        catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && File.Exists(target))
        {
            File.Move(target, target + UpdateInstaller.OldSuffix, overwrite: true);
            File.Move(partial, target);
        }
    }
}

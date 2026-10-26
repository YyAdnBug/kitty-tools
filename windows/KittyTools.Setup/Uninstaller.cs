// 卸载流程（PLAN-setup S9）。安装目录里的 Uninstall.exe 先把自己复制到 %TEMP%\KittyTools-uninstall-<随机>\，
// 带上 --from <安装目录> --wait-pid <自己的进程号> 启动那份，自己马上退出（自己所在的文件夹删不掉）。
// %TEMP% 那份：确认（可选「同时删除我的数据」）→ 让程序退出（S5）→ 开始菜单快捷方式 → 开机启动 → 凭据 →
// 数据目录进回收站（勾了才做）→ 安装目录（SetupRules.PlanRemoval：§2.3 的检查都过才整个删）→ 「设置 › 应用」的登记 → 已卸载。
// --quiet 不弹界面：原来那份同样只负责转过去就退出，调用方要等结果就看登记和安装目录有没有消失（tools/setup-e2e.ps1 的做法）。
using System.Diagnostics;
using System.Globalization;
using KittyTools.Core;

namespace KittyTools.Setup;

internal sealed class Uninstaller
{
    private const string TempPrefix = "KittyTools-uninstall-";
    private const int IdUninstall = 100;
    private const int IdRetry = 101;
    private const int IdFinish = 102;

    private readonly string _dir;
    private readonly SetupNames _names;
    private readonly List<string> _notes = [];
    private bool _withData;
    private bool _leftover;
    private int _exitCode = ExitCodes.Cancelled;

    private volatile int _percent;
    private volatile Outcome _outcome;
    private volatile string? _error;

    private Uninstaller(string dir, SetupNames names, bool withData)
    {
        _dir = dir;
        _names = names;
        _withData = withData;
    }

    private enum Outcome
    {
        Working,
        Done,
        AppRunning,
        Failed,
    }

    public static int Run(string self, SetupArgs args, SetupNames names)
    {
        if (args.From is null)
        {
            return Relocate(self, args);
        }

        var tempDir = Path.GetDirectoryName(self)!;
        CleanStaleCopies(tempDir);
        if (args.WaitPid is { } pid)
        {
            WaitForExit(pid);
        }

        var uninstaller = new Uninstaller(SetupRules.Normalize(Path.GetFullPath(args.From)), names, args.WithData);
        try
        {
            var code = args.Quiet ? uninstaller.RunQuiet() : uninstaller.RunInteractive();
            SetupLog.Write($"uninstall.exit {code}");
            return code;
        }
        finally
        {
            // 只收拾 Relocate 复制出来的那份；别人手动带 --from 跑的不动。
            if (Path.GetFileName(tempDir).StartsWith(TempPrefix, StringComparison.OrdinalIgnoreCase))
            {
                SystemSteps.DeleteAfterReboot(self);
                SystemSteps.DeleteAfterReboot(tempDir);
            }
        }
    }

    /// <summary>删掉以前留在 %TEMP% 里的卸载程序副本（keep 是自己正在用的那份，不删）。正在跑的删不掉，跳过。</summary>
    public static void CleanStaleCopies(string? keep)
    {
        try
        {
            foreach (var dir in Directory.EnumerateDirectories(Path.GetTempPath(), TempPrefix + "*"))
            {
                if (keep is not null && SetupRules.SamePath(dir, keep))
                {
                    continue;
                }

                try
                {
                    Directory.Delete(dir, recursive: true);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    // 还有一份卸载程序在跑：下次再清。
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetupLog.Write($"temp.clean-failed {ex.GetType().Name}");
        }
    }

    private static int Relocate(string self, SetupArgs args)
    {
        var installDir = Path.GetDirectoryName(self)!;
        var folder = Path.Combine(Path.GetTempPath(), TempPrefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var copy = Path.Combine(folder, SetupRules.UninstallerName);
        File.Copy(self, copy);

        var start = new ProcessStartInfo(copy) { UseShellExecute = false, WorkingDirectory = folder };
        start.ArgumentList.Add("--from");
        start.ArgumentList.Add(installDir);
        start.ArgumentList.Add("--wait-pid");
        start.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        if (args.Quiet)
        {
            start.ArgumentList.Add("--quiet");
        }

        if (args.WithData)
        {
            start.ArgumentList.Add("--with-data");
        }

        Process.Start(start)?.Dispose();
        SetupLog.Write("uninstall.relocated");
        return ExitCodes.Ok;
    }

    private static void WaitForExit(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            if (!process.WaitForExit(10_000))
            {
                SetupLog.Write("uninstall.parent-still-running");
            }
        }
        catch (ArgumentException)
        {
            // 已经退了。
        }
        catch (InvalidOperationException)
        {
            // 同上。
        }
    }

    private int RunQuiet()
    {
        Work();
        if (_leftover)
        {
            SetupLog.Write("uninstall.leftover (other files in the folder)");
        }

        return _outcome switch
        {
            Outcome.Done => ExitCodes.Ok,
            Outcome.AppRunning => ExitCodes.AppRunning,
            _ => ExitCodes.Error,
        };
    }

    private int RunInteractive()
    {
        var confirm = new Page
        {
            Instruction = "卸载 Kitty Tools？",
            Content = $"会删掉程序文件、开始菜单里的快捷方式、开机启动和凭据管理器里存的密钥。\n装在：{_dir}",
            Checkbox = "同时删除我的数据（剪贴板历史、设置等，挪进回收站）",
            Checked = _withData,
            Buttons = [(IdUninstall, "卸载"), (SetupUi.IdCancel, "取消")],
            DefaultButton = SetupUi.IdCancel,
            Clicked = (button, withData) =>
            {
                if (button != IdUninstall)
                {
                    return false;
                }

                _withData = withData;
                StartWork();
                return true;
            },
        };
        return SetupUi.Run(confirm) ? _exitCode : ExitCodes.Error;
    }

    private void StartWork()
    {
        _percent = 0;
        _error = null;
        _outcome = Outcome.Working;
        SetupUi.Navigate(new Page
        {
            Instruction = "正在卸载…",
            Content = _dir,
            Progress = true,
            Buttons = [(SetupUi.IdCancel, "取消")],
            Tick = OnTick,
        });
        var thread = new Thread(() =>
        {
            SystemSteps.InitializeCom(); // 回收站走的是外壳的文件操作
            Work();
        })
        {
            IsBackground = true,
            Name = "KittyTools.Setup.Uninstall",
        };
        thread.Start();
    }

    private void OnTick()
    {
        SetupUi.SetProgress(_percent);
        switch (_outcome)
        {
            case Outcome.Done:
                if (_leftover)
                {
                    OpenFolder(_dir);
                }

                SetupUi.Navigate(new Page
                {
                    Instruction = "已卸载 Kitty Tools",
                    Content = _notes.Count > 0 ? string.Join("\n", _notes) : null,
                    Icon = _notes.Count > 0 ? PageIcon.Warning : PageIcon.None,
                    Buttons = [(IdFinish, "完成")],
                    DefaultButton = IdFinish,
                    Clicked = (_, _) =>
                    {
                        _exitCode = ExitCodes.Ok;
                        return false;
                    },
                });
                break;
            case Outcome.AppRunning:
                SetupUi.Navigate(new Page
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
                });
                break;
            case Outcome.Failed:
                SetupUi.Navigate(new Page
                {
                    Instruction = "没能卸载干净",
                    Content = _error,
                    Icon = PageIcon.Error,
                    Buttons = [(SetupUi.IdCancel, "关闭")],
                    Clicked = (_, _) =>
                    {
                        _exitCode = ExitCodes.Error;
                        return false;
                    },
                });
                break;
        }
    }

    /// <summary>真正干活，结果写进 _outcome / _error。不碰界面。</summary>
    private void Work()
    {
        try
        {
            if (!SystemSteps.QuitRunningApp(_names))
            {
                Finish(Outcome.AppRunning, null);
                return;
            }

            _percent = 20;
            SystemSteps.RemoveShortcut(_names);
            SystemSteps.RemoveAutostart(_names, Path.Combine(_dir, SetupRules.ExeName));
            SetupLog.Write($"uninstall.credentials removed={SystemSteps.DeleteCredentials(_names.CredentialPrefix)}");
            _percent = 40;
            if (_withData)
            {
                var data = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), _names.DataFolder);
                if (!SystemSteps.Recycle(data))
                {
                    _notes.Add($"数据文件夹没删干净，可能有文件还被占着，请自己删：{data}");
                }
            }

            _percent = 70;
            RemoveInstallDir();
            SystemSteps.Unregister(_names, _dir);
            _percent = 100;
            Finish(Outcome.Done, null);
        }
        catch (Exception ex)
        {
            SetupLog.Write($"uninstall.failed {ex.GetType().Name} {ex.Message}");
            Finish(Outcome.Failed, $"卸载时出错，详情在日志里：{SetupLog.Path}");
        }
    }

    private void Finish(Outcome outcome, string? error)
    {
        _error = error;
        _outcome = outcome;
    }

    /// <summary>§2.3：检查都过才整个删；否则只删认得的文件，剩下的留给用户看。</summary>
    private void RemoveInstallDir()
    {
        if (!Directory.Exists(_dir))
        {
            return;
        }

        var present = Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories)
            .Select(file => Path.GetRelativePath(_dir, file))
            .ToList();
        var plan = SetupRules.PlanRemoval(_dir, present, SetupRules.ReadMarker(_dir), SystemSteps.Folders());
        SetupLog.Write($"uninstall.plan whole={plan.WholeDirectory} ours={plan.Files.Count}/{present.Count}");
        if (plan.WholeDirectory && SystemSteps.DeleteDirectory(_dir))
        {
            return;
        }

        SystemSteps.DeleteFiles(_dir, plan.Files);
        if (Directory.Exists(_dir))
        {
            _leftover = true;
            _notes.Add($"这个文件夹里还有别的东西，没有整个删掉：{_dir}");
        }
    }

    private static void OpenFolder(string dir)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"\"{dir}\"", UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException)
        {
            SetupLog.Write($"uninstall.open-folder-failed {ex.GetType().Name}");
        }
    }
}

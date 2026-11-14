// 脚本命令从哪来（PLAN-v18 L1，mac ScriptLibrary.swift）：数据目录里的默认文件夹 scripts，加上自己添加的文件夹（设置
// LauncherScriptFolders，这台电脑自己的路径，不导出；只读、不扫子文件夹）。自带的（D8）是 Core BuiltinTools，接在 Scripts 后面。
// 每次呼出启动器在后台重读一遍（几个小文件的开头，几毫秒；另加的文件夹可能在网络盘上，碰它的都不在界面线程），读完换上、
// 通知启动器按新的重搜；读的时候再要就这一遍读完再读一遍。读不成的记下原因（设置页列出来）。
// 下载来的（:Zone.Identifier）先不给跑，第一次在启动器里看全文；它的网址图标、脚本文件夹外面的图片不用（能当信标）。
// 从剪贴板新建先看全文（ScriptTextWindow.ReviewNew），存进默认文件夹；默认文件夹第一次建时放两个样板（第 8 批）。
// ponytail: 每次呼出都整个重读，不比修改时间；脚本多到几百个、或文件夹在很慢的网络盘上时，改成按修改时间认。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal static class ScriptLibrary
{
    public sealed record Problem(string Path, ScriptProblem Kind);

    private static readonly object Gate = new();
    private static IReadOnlyList<ScriptCommand> _scripts = Array.Empty<ScriptCommand>();
    private static IReadOnlyList<Problem> _problems = Array.Empty<Problem>();
    private static bool _scanning;
    private static bool _again;
    private static DispatcherQueue? _dispatcher;

    /// <summary>读完换上之后（在界面线程上）：启动器开着时重搜、设置页重画。</summary>
    public static event Action? Changed;

    public static bool IsLoaded { get; private set; }

    public static string DefaultFolder => Path.Combine(Paths.DataDirectory, "scripts");

    /// <summary>自己的脚本在前，自带的命令（PLAN-v18 D8，BuiltinTools）在后：同一个关键词时用自己的。</summary>
    public static IReadOnlyList<ScriptCommand> Scripts
    {
        get
        {
            lock (Gate)
            {
                return _scripts.Concat(BuiltinTools.Commands).ToList();
            }
        }
    }

    public static IReadOnlyList<Problem> Problems
    {
        get
        {
            lock (Gate)
            {
                return _problems;
            }
        }
    }

    /// <summary>默认文件夹在前，再是自己加的（去重）。</summary>
    public static IReadOnlyList<string> Folders
        => new[] { DefaultFolder }.Concat(SettingsService.Current.LauncherScriptFolders ?? new List<string>())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    /// <summary>读完了、一个自己的脚本都没有（自带的不算）：设置里出「还没有自己的脚本」那一行。</summary>
    public static bool HasNoOwnScripts => IsLoaded && Scripts.All(script => script.IsBundled);

    /// <summary>默认文件夹，没有就建；第一次建的时候放两个样板（查天气、数字数，PLAN-v18 D8「另带 1–2 个 .ps1」）。</summary>
    public static string EnsureDefaultFolder() => EnsureFolder(DefaultFolder);

    /// <summary>同上，文件夹由调用方给（脚本自检在临时目录里验）。</summary>
    public static string EnsureFolder(string folder)
    {
        if (!Directory.Exists(folder))
        {
            Directory.CreateDirectory(folder);
            foreach (var (name, text) in new[] { (ScriptTemplates.ExampleName, ScriptTemplates.Example), (ScriptTemplates.CountExampleName, ScriptTemplates.CountExample) })
            {
                try
                {
                    File.WriteAllBytes(Path.Combine(folder, name), ScriptTemplates.Bytes(text + "\n", ScriptLanguage.PowerShell));
                }
                catch (Exception ex)
                {
                    Log.Warn($"script.sample-failed {ex.GetType().Name}");
                }
            }
        }

        return folder;
    }

    /// <summary>存一段脚本（新建、从剪贴板新建、用例子新建）：默认文件夹里起一个没用过的名字；返回路径，写不进去是 null。</summary>
    public static string? Save(string text, string name, ScriptLanguage language)
    {
        try
        {
            var folder = EnsureDefaultFolder();
            var path = Path.Combine(folder, ScriptTemplates.FreeName(name, candidate => File.Exists(Path.Combine(folder, candidate))));
            File.WriteAllBytes(path, ScriptTemplates.Bytes(text, language));
            Refresh();
            return path;
        }
        catch (Exception ex)
        {
            Log.Warn($"script.save-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>用编辑器打开：文件自己的「编辑」（.ps1 默认是记事本或 ISE），没有就用记事本。不用「打开」——.ps1 / .cmd 双击就跑了。</summary>
    public static void Edit(string path)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true, Verb = "edit" });
        }
        catch (Exception)
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe") { ArgumentList = { path }, UseShellExecute = false });
            }
            catch (Exception ex)
            {
                Log.Warn($"script.edit-failed {ex.GetType().Name}");
            }
        }
    }

    /// <summary>装了 Python 启动器（py.exe）：Windows 目录、用户装的 Launcher 目录、PATH 里找。</summary>
    public static bool PythonAvailable()
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "py.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Python\Launcher\py.exe"),
        }.Concat((ScriptRunner.RegistryPath() ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Select(folder => Path.Combine(folder.Trim(), "py.exe")));
        return candidates.Any(File.Exists);
    }

    /// <summary>后台重读一遍（脚本命令关着时不读）。</summary>
    public static void Refresh()
    {
        _dispatcher ??= DispatcherQueue.GetForCurrentThread();
        if (!SettingsService.Current.LauncherScripts)
        {
            return;
        }

        lock (Gate)
        {
            if (_scanning)
            {
                _again = true;
                return;
            }

            _scanning = true;
        }

        _ = Task.Run(() =>
        {
            while (true)
            {
                var (scripts, problems) = Scan(Folders, PythonAvailable());
                bool again;
                lock (Gate)
                {
                    _scripts = scripts;
                    _problems = problems;
                    again = _again;
                    _again = false;
                    _scanning = again;
                }

                IsLoaded = true;
                _dispatcher?.TryEnqueue(() => Changed?.Invoke());
                if (!again)
                {
                    return;
                }
            }
        });
    }

    /// <summary>读几个文件夹的顶层（不进子文件夹）：一个文件一条命令，读不成的记原因。</summary>
    public static (List<ScriptCommand> Scripts, List<Problem> Problems) Scan(IEnumerable<string> folders, bool python)
    {
        var scripts = new List<ScriptCommand>();
        var problems = new List<Problem>();
        foreach (var folder in folders)
        {
            if (!Directory.Exists(folder))
            {
                continue;
            }

            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(folder).OrderBy(file => file, StringComparer.OrdinalIgnoreCase).ToList();
            }
            catch (Exception ex)
            {
                Log.Warn($"script.scan-failed {ex.GetType().Name}");
                continue;
            }

            foreach (var file in files)
            {
                string head;
                try
                {
                    head = ReadHead(file);
                }
                catch (Exception)
                {
                    if (ScriptCommand.InterpreterFor(file, true) is not null)
                    {
                        problems.Add(new Problem(file, ScriptProblem.Unreadable));
                    }

                    continue;
                }

                switch (ScriptCommand.Parse(head, file, python))
                {
                    case null:
                        break;
                    case { Problem: { } problem }:
                        problems.Add(new Problem(file, problem));
                        break;
                    case { Script: { } script }:
                        var downloaded = ScriptRunner.IsDownloaded(file);
                        scripts.Add(downloaded ? DropUntrustedIcons(script) with { IsDownloaded = true } : script);
                        break;
                }
            }
        }

        return (scripts, problems);
    }

    /// <summary>开头最多 8 KB：带 BOM 的按 BOM，合法的 UTF-8 按 UTF-8，不然按系统的 ANSI 代码页（GBK）。</summary>
    private static string ReadHead(string path)
    {
        using var stream = File.OpenRead(path);
        var buffer = new byte[ScriptCommand.HeaderBytes];
        var read = stream.Read(buffer, 0, buffer.Length);
        var span = buffer.AsSpan(0, read);
        if (span.StartsWith(new byte[] { 0xFF, 0xFE }))
        {
            return Encoding.Unicode.GetString(span[2..]);
        }

        if (ScriptLaunch.LooksUtf8(span) || !span.ToArray().Any(value => value >= 0x80))
        {
            var text = Encoding.UTF8.GetString(span);
            return text.TrimStart('﻿');
        }

        return Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.ANSICodePage).GetString(span);
    }

    /// <summary>下载来、还没看过的：网址图标、脚本文件夹外面的图片不用（mac dropUntrustedIcons）。</summary>
    private static ScriptCommand DropUntrustedIcons(ScriptCommand script)
    {
        ScriptIcon? Keep(ScriptIcon? icon) => icon switch
        {
            ScriptIcon.Remote => null,
            ScriptIcon.Image image when !string.Equals(Path.GetDirectoryName(image.Path), script.Folder, StringComparison.OrdinalIgnoreCase) => null,
            ScriptIcon.Image image when new FileInfo(image.Path).LinkTarget is not null => null,
            _ => icon,
        };
        return script with { Icon = Keep(script.Icon), IconDark = Keep(script.IconDark) };
    }
}

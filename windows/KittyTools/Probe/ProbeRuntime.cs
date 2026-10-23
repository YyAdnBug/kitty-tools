// 第 0 批的探针运行时：隐藏窗口 + 托盘 + 热键 + 一个命名管道。
// 管道让外部脚本（windows/build/batch-0/）能确定地驱动各项实测：
// 合成 / 伪造热键、开收浮层、读内存、截图、读 UIA、退出。第 1 批这整套会删掉。
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.Win32;
using Windows.Win32.System.ProcessStatus;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal sealed class ProbeRuntime
{
    private const string PipeName = "KittyTools.Probe";
    private static ProbeRuntime? _current;
    private static ElementTheme _forcedTheme = ElementTheme.Default;

    private readonly DispatcherQueue _dispatcher;
    private readonly CancellationTokenSource _shutdown = new();
    private Window? _keeper;
    private int _messageCount;

    private ProbeRuntime(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public static ElementTheme ForcedTheme => _forcedTheme;

    public static ProbeRuntime Start()
    {
        var runtime = new ProbeRuntime(DispatcherQueue.GetForCurrentThread());
        _current = runtime;
        runtime.Initialize();
        return runtime;
    }

    public static void Exit()
    {
        _current?.Shutdown();
    }

    private void Initialize()
    {
        ProbeLog.Init();
        ReadThemeArgument();
        ApplyAccent();

        ProbeLog.Write(
            "app.start",
            ("version", typeof(ProbeRuntime).Assembly.GetName().Version?.ToString() ?? "?"),
            ("pid", Environment.ProcessId));

        if (!HiddenWindow.Create())
        {
            Application.Current.Exit();
            return;
        }

        ProbeLog.Write("app.dpi", ("dpi", PInvoke.GetDpiForWindow(HiddenWindow.Hwnd)));

        // WinUI 3 在最后一个 XAML 窗口关闭时会结束进程；常驻托盘需要留一个永不关闭的
        // 隐藏窗口。它不激活、不进任务栏和 Alt+Tab，只负责把 XAML 生命周期撑住。
        _keeper = new Window { Title = "Kitty Tools" };
        _keeper.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(-32000, -32000, 1, 1));
        _keeper.AppWindow.IsShownInSwitchers = false;
        ProbeLog.Write("app.keeper", ("hwnd", WinRT.Interop.WindowNative.GetWindowHandle(_keeper).ToInt64()));

        HiddenWindow.Message += OnMessage;
        Tray.Add();
        HotKeys.RegisterAll();
        StartPipeServer();
        ProbeLog.Write("app.ready", ("log", ProbeLog.Path ?? string.Empty));
    }

    private void ReadThemeArgument()
    {
        var args = Environment.GetCommandLineArgs();
        for (var i = 1; i < args.Length - 1; i++)
        {
            if (args[i] == "--theme")
            {
                _forcedTheme = args[i + 1].Equals("dark", StringComparison.OrdinalIgnoreCase)
                    ? ElementTheme.Dark
                    : ElementTheme.Light;
                ProbeLog.Write("app.theme", ("theme", args[i + 1]));
            }
        }
    }

    private static void ApplyAccent()
    {
        var resources = Application.Current.Resources;
        resources["SystemAccentColor"] = Theme.BrandPink;
        resources["SystemAccentColorLight1"] = Lighten(Theme.BrandPink, 0.12);
        resources["SystemAccentColorLight2"] = Lighten(Theme.BrandPink, 0.24);
        resources["SystemAccentColorLight3"] = Lighten(Theme.BrandPink, 0.36);
        resources["SystemAccentColorDark1"] = Theme.BrandPinkDeep;
        resources["SystemAccentColorDark2"] = Lighten(Theme.BrandPinkDeep, -0.10);
        resources["SystemAccentColorDark3"] = Lighten(Theme.BrandPinkDeep, -0.20);
    }

    private static Windows.UI.Color Lighten(Windows.UI.Color color, double amount)
    {
        byte Channel(byte value) => (byte)Math.Clamp(value + (amount * 255), 0, 255);
        return Windows.UI.Color.FromArgb(color.A, Channel(color.R), Channel(color.G), Channel(color.B));
    }

    private void OnMessage(uint msg, Windows.Win32.Foundation.WPARAM wParam, Windows.Win32.Foundation.LPARAM lParam)
    {
        if (_messageCount < 40)
        {
            _messageCount++;
            ProbeLog.Write("hidden.message", ("msg", msg));
        }

        switch (msg)
        {
            case PInvoke.WM_HOTKEY:
                HotKeys.OnHotKey((int)wParam.Value);
                break;
            case PInvoke.WM_CLIPBOARDUPDATE:
                ProbeLog.Write("clipboard.update", ("sequence", PInvoke.GetClipboardSequenceNumber()));
                break;
            default:
                if (msg == 0x8000 + 1)
                {
                    Tray.OnCallback(msg, wParam, lParam);
                }
                break;
        }
    }

    private void StartPipeServer()
    {
        var thread = new Thread(PipeLoop)
        {
            IsBackground = true,
            Name = "KittyTools.ProbePipe",
        };
        thread.Start();
    }

    private void PipeLoop()
    {
        while (!_shutdown.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte);
                pipe.WaitForConnection();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
                while (pipe.IsConnected && !_shutdown.IsCancellationRequested)
                {
                    var line = reader.ReadLine();
                    if (line is null)
                    {
                        break;
                    }

                    writer.WriteLine(Execute(line));
                }
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException)
            {
                if (_shutdown.IsCancellationRequested)
                {
                    return;
                }
            }
            catch (Exception ex)
            {
                ProbeLog.Write("pipe.error", ("type", ex.GetType().Name));
            }
        }
    }

    private string Execute(string line)
    {
        var separator = line.IndexOf(' ');
        var command = separator < 0 ? line.Trim() : line[..separator];
        var argument = separator < 0 ? string.Empty : line[(separator + 1)..];

        var done = new ManualResetEventSlim();
        var result = "{\"ok\":false}";
        _dispatcher.TryEnqueue(() =>
        {
            try
            {
                result = ExecuteOnUi(command, argument);
            }
            catch (Exception ex)
            {
                result = $"{{\"ok\":false,\"error\":\"{ex.GetType().Name}\"}}";
                ProbeLog.Write("pipe.command-error", ("command", command), ("type", ex.GetType().Name));
                try
                {
                    File.AppendAllText(
                        Path.Combine(Path.GetTempPath(), "kitty-crash.txt"),
                        $"{DateTime.Now:O} command {command}: {ex}\n\n");
                }
                catch
                {
                    // 调试日志写不出来就算了。
                }
            }
            finally
            {
                done.Set();
            }
        });

        return done.Wait(TimeSpan.FromSeconds(30)) ? result : "{\"ok\":false,\"error\":\"timeout\"}";
    }

    private string ExecuteOnUi(string command, string argument)
    {
        switch (command)
        {
            case "ping":
                return "{\"ok\":true}";
            case "mem":
                return MemoryProbe.SnapshotJson(argument);
            case "show":
                OverlayHost.ToggleForProbe(argument == "launcher" ? OverlayKind.Launcher : OverlayKind.Clipboard);
                return "{\"ok\":true}";
            case "hide":
                OverlayHost.Hide(restoreForeground: true);
                return "{\"ok\":true}";
            case "press":
                return Press(argument);
            case "fakehotkey":
                PInvoke.PostMessage(HiddenWindow.Hwnd, PInvoke.WM_HOTKEY, int.TryParse(argument, out var id) ? (nuint)id : 1, default);
                return "{\"ok\":true}";
            case "type":
                return Keyboard.SendText(argument) ? "{\"ok\":true}" : "{\"ok\":false}";
            case "enter":
                return Keyboard.SendEnter() ? "{\"ok\":true}" : "{\"ok\":false}";
            case "esc":
                return Keyboard.SendEscape() ? "{\"ok\":true}" : "{\"ok\":false}";
            case "uia":
                return ReadSelectionForProbe(null);
            case "uiaselect":
                return ReadSelectionForProbe(argument);
            case "focus":
                return FocusWindow(argument);
            case "elev":
                return int.TryParse(argument, out var elevPid)
                    ? $"{{\"ok\":true,\"elevated\":{(Foreground.IsProcessElevated((uint)elevPid) ? "true" : "false")}}}"
                    : "{\"ok\":false}";
            case "paste":
                return PasteDirect(argument);
            case "tray-menu-count":
                return $"{{\"ok\":true,\"count\":{Tray.MenuItemCount()}}}";
            case "tray-menu-show":
                var closer = new Thread(() =>
                {
                    Thread.Sleep(1200);
                    Keyboard.SendEscape();
                })
                {
                    IsBackground = true,
                };
                closer.Start();
                Tray.ShowMenu();
                return "{\"ok\":true}";
            case "capture-open":
                CaptureHost.Open(Stopwatch.GetTimestamp(), verifyMode: false);
                return "{\"ok\":true}";
            case "capture-close":
                CaptureHost.CloseAll();
                CaptureHost.Collect();
                return "{\"ok\":true}";
            case "destroy-overlay":
                OverlayHost.Destroy();
                return "{\"ok\":true}";
            case "capture-verify":
                CaptureHost.Verify();
                return "{\"ok\":true}";
            case "capture-screen-verify":
                CaptureHost.ScreenVerify();
                return "{\"ok\":true}";
            case "screenshot":
                CaptureHost.SaveFrozenPng(argument);
                return "{\"ok\":true}";
            case "quit":
                Shutdown();
                return "{\"ok\":true}";
            default:
                return "{\"ok\":false,\"error\":\"unknown\"}";
        }
    }

    private string FocusWindow(string argument)
    {
        if (!long.TryParse(argument, out var value))
        {
            return "{\"ok\":false}";
        }

        var reached = Foreground.Restore(new Windows.Win32.Foundation.HWND((IntPtr)value));
        return $"{{\"ok\":{(reached ? "true" : "false")}}}";
    }

    private string PasteDirect(string argument)
    {
        var parts = argument.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || !long.TryParse(parts[0], out var hwndValue))
        {
            return "{\"ok\":false}";
        }

        var ok = Paster.PasteText(new Windows.Win32.Foundation.HWND((IntPtr)hwndValue), parts[1]);
        return $"{{\"ok\":{(ok ? "true" : "false")}}}";
    }

    private string ReadSelectionForProbe(string? selectText)
    {
        var (text, status, ms) = UiaReader.ReadFocusedSelection(500, selectText);
        var hash = text.Length == 0
            ? string.Empty
            : Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..16];
        ProbeLog.Write("uia.read", ("status", status), ("chars", text.Length), ("ms", ms));
        return $"{{\"ok\":{(status == "ok" ? "true" : "false")},\"status\":\"{status}\",\"chars\":{text.Length},\"hash\":\"{hash}\",\"ms\":{ms.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)}}}";
    }

    private string Press(string name)
    {
        var t0 = Stopwatch.GetTimestamp();
        ProbeLog.Write("input.press", ("name", name), ("t0", t0));
        var ok = name switch
        {
            "alt+c" => Keyboard.SendHotkey((VIRTUAL_KEY)'C'),
            "alt+space" => Keyboard.SendHotkey((VIRTUAL_KEY)0x20),
            "alt+x" => Keyboard.SendHotkey((VIRTUAL_KEY)'X'),
            _ => false,
        };
        return $"{{\"ok\":{(ok ? "true" : "false")},\"t0\":{t0}}}";
    }

    private void Shutdown()
    {
        if (_shutdown.IsCancellationRequested)
        {
            return;
        }

        ProbeLog.Write("app.exit");
        _shutdown.Cancel();
        HotKeys.UnregisterAll();
        Tray.Remove();
        Application.Current.Exit();
    }
}

// 内存口径同 PLAN §11：任务管理器「详细信息」页的「内存(专用工作集)」，
// 代码里取 PROCESS_MEMORY_COUNTERS_EX2.PrivateWorkingSetSize。
internal static unsafe class MemoryProbe
{
    public static long PrivateWorkingSet { get; private set; }

    public static long WorkingSet { get; private set; }

    public static bool Read()
    {
        var counters = new PROCESS_MEMORY_COUNTERS_EX2
        {
            cb = (uint)sizeof(PROCESS_MEMORY_COUNTERS_EX2),
        };

        if (!PInvoke.GetProcessMemoryInfo(
                PInvoke.GetCurrentProcess(),
                (PROCESS_MEMORY_COUNTERS*)&counters,
                counters.cb))
        {
            return false;
        }

        PrivateWorkingSet = (long)counters.PrivateWorkingSetSize;
        WorkingSet = (long)counters.WorkingSetSize;
        return true;
    }

    public static string SnapshotJson(string stage)
    {
        Read();
        ProbeLog.Write(
            "memory",
            ("stage", stage),
            ("private_ws", PrivateWorkingSet),
            ("working_set", WorkingSet));
        return $"{{\"ok\":true,\"stage\":\"{stage}\",\"private_ws\":{PrivateWorkingSet},\"working_set\":{WorkingSet}}}";
    }
}

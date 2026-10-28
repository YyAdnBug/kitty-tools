// 启动器 kill / port / quit / hide / forcequit 列的进程（PLAN-v9-launcher R11，照 mac Processes / SystemCommands.targets）：
// 在线程池里拍一次快照——Toolhelp 拿全部进程（PID、父进程、exe 名），只留这个会话里的；有没有看得见的窗口按 Alt+Tab 的规矩数
// （看得见、没有所有者、不是工具窗口、没被藏起来、有标题；任务栏、桌面那几扇不算）；在监听的 TCP 端口从 PortTable；内存是工作集。
// 不列本 App 和它起的子进程。kill 不列有窗口的程序（它们在 quit 里，同 mac 不列程序坞里的 App）；
// quit / forcequit 不列资源管理器（关掉它 = 任务栏、桌面一起没了，同 mac 的访达只能隐藏）。
// ponytail: 商店应用的窗口挂在 ApplicationFrameHost 名下，一个进程装着好几个应用，先不列；要列得按窗口拆行。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed record ProcessSnapshot(List<LauncherProcess> Processes, Dictionary<int, int> Parents, int ForegroundPid);

internal static unsafe partial class RunningProcesses
{
    private const int WmClose = 0x0010;
    private const int SwMinimize = 6;
    private const int GwOwner = 4;
    private const int GwlExStyle = -20;
    private const long WsExToolWindow = 0x00000080;
    private const long WsExAppWindow = 0x00040000;

    /// <summary>不算「应用窗口」的类名：任务栏、桌面、开始菜单那几扇。</summary>
    private static readonly HashSet<string> ShellClasses = new(StringComparer.Ordinal)
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW", "Windows.UI.Core.CoreWindow",
    };

    private static Dictionary<int, List<IntPtr>>? _collecting;

    /// <summary>拍一次快照（线程池里调；几十毫秒）。foregroundPid：呼出启动器之前在前台的那个程序（UI 线程上取好传进来）。</summary>
    public static ProcessSnapshot Take(int foregroundPid)
    {
        var own = Environment.ProcessId;
        var session = Process.GetCurrentProcess().SessionId;
        var parents = new Dictionary<int, int>();
        foreach (var (pid, entry) in ClipboardFormats.SnapshotProcesses())
        {
            parents[(int)pid] = (int)entry.Parent;
        }

        var windows = AppWindows();
        var ports = new Dictionary<int, List<int>>();
        try
        {
            foreach (var row in PortTable.Read().Where(row => row.Protocol == "TCP"))
            {
                if (!ports.TryGetValue(row.Pid, out var list))
                {
                    ports[row.Pid] = list = new List<int>();
                }

                if (!list.Contains(row.Port))
                {
                    list.Add(row.Port);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.ports-failed {ex.GetType().Name}");
        }

        var processes = new List<LauncherProcess>();
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                var pid = process.Id;
                if (pid == own || pid <= 4 || process.SessionId != session ||
                    (parents.TryGetValue(pid, out var parent) && parent == own))
                {
                    continue;
                }

                var path = ClipboardFormats.ProcessImage((uint)pid);
                var name = process.ProcessName;
                var hasWindow = windows.ContainsKey(pid) &&
                                !name.Equals("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase);
                var label = hasWindow && path is not null ? ClipboardFormats.DisplayName(path) : name;
                long memory = 0;
                try
                {
                    memory = process.WorkingSet64;
                }
                catch
                {
                    // 别的用户的进程读不到，记 0。
                }

                processes.Add(new LauncherProcess(
                    pid,
                    name,
                    string.IsNullOrWhiteSpace(label) ? name : label,
                    memory,
                    ports.TryGetValue(pid, out var listening)
                        ? listening.OrderBy(port => port).ToList()
                        : (IReadOnlyList<int>)Array.Empty<int>(),
                    hasWindow,
                    path));
            }
            catch
            {
                // 进程刚好退出。
            }
            finally
            {
                process.Dispose();
            }
        }

        return new ProcessSnapshot(processes, parents, foregroundPid);
    }

    /// <summary>kill 的行：没有窗口的进程，监听端口的在前、再是不在系统目录里的、再按内存（mac Processes.targets）。</summary>
    public static List<LauncherItem> KillTargets(ProcessSnapshot snapshot)
        => LauncherCommands.SortProcesses(
                snapshot.Processes.Where(process => !process.HasWindow), WindowsDirectory)
            .Select(LauncherCommands.ProcessItem)
            .ToList();

    /// <summary>port 的行：一个在监听的 TCP 端口一行（有窗口的程序也列，同 mac 程序坞里的 App）。</summary>
    public static List<LauncherItem> PortTargets(ProcessSnapshot snapshot)
        => LauncherCommands.PortItems(snapshot.Processes.Where(process => process.Ports.Count > 0).ToList(), snapshot.Parents);

    /// <summary>quit / hide / forcequit 的行：有窗口的程序，前台那个排第一；quit / forcequit 不列资源管理器。</summary>
    public static List<LauncherItem> AppTargets(ProcessSnapshot snapshot, LauncherMode mode, string keyword)
        => LauncherCommands.AppTargets(
            snapshot.Processes
                .Where(process => process.HasWindow)
                .Where(process => mode == LauncherMode.Hide || !process.Name.Equals("explorer", StringComparison.OrdinalIgnoreCase)),
            snapshot.ForegroundPid,
            keyword);

    private static string WindowsDirectory => Environment.GetFolderPath(Environment.SpecialFolder.Windows);

    /// <summary>退出：给它每一扇应用窗口发 WM_CLOSE（有没存的内容它自己会问）。成功返回 null，否则给用户看的原因。</summary>
    public static string? Quit(int pid)
    {
        var windows = AppWindows();
        if (!windows.TryGetValue(pid, out var list) || list.Count == 0)
        {
            return "它已经没有打开的窗口了";
        }

        foreach (var hwnd in list)
        {
            PostMessageW(hwnd, WmClose, IntPtr.Zero, IntPtr.Zero);
        }

        return null;
    }

    /// <summary>最小化它的每一扇应用窗口（mac 的「隐藏」）。</summary>
    public static string? Minimize(int pid)
    {
        var windows = AppWindows();
        if (!windows.TryGetValue(pid, out var list) || list.Count == 0)
        {
            return "它已经没有打开的窗口了";
        }

        foreach (var hwnd in list)
        {
            ShowWindow(hwnd, SwMinimize);
        }

        return null;
    }

    /// <summary>结束进程（TerminateProcess，硬结束）；成功返回 null，失败返回原因。</summary>
    public static string? Kill(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            process.Kill(entireProcessTree: false);
            return null;
        }
        catch (Exception ex)
        {
            return ex switch
            {
                System.ComponentModel.Win32Exception => "没有权限（它属于别的用户，或是用管理员身份运行的）",
                UnauthorizedAccessException => "没有权限（它属于别的用户，或是用管理员身份运行的）",
                InvalidOperationException => "它已经不在运行了",
                ArgumentException => "它已经不在运行了",
                _ => ex.GetType().Name,
            };
        }
    }

    /// <summary>PID → 它的应用窗口（Alt+Tab 能切到的那种）。</summary>
    private static Dictionary<int, List<IntPtr>> AppWindows()
    {
        var result = new Dictionary<int, List<IntPtr>>();
        lock (ShellClasses)
        {
            _collecting = result;
            var callback = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)&Collect;
            EnumWindows(callback, IntPtr.Zero);
            _collecting = null;
        }

        return result;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static int Collect(IntPtr hwnd, IntPtr data)
    {
        try
        {
            if (_collecting is null || !IsWindowVisible(hwnd) || GetWindow(hwnd, GwOwner) != IntPtr.Zero)
            {
                return 1;
            }

            var style = (long)GetWindowLongPtrW(hwnd, GwlExStyle);
            if ((style & WsExToolWindow) != 0 && (style & WsExAppWindow) == 0)
            {
                return 1;
            }

            if (DwmGetWindowAttribute(hwnd, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            {
                return 1;
            }

            if (GetWindowTextLengthW(hwnd) == 0)
            {
                return 1;
            }

            char* buffer = stackalloc char[64];
            var length = GetClassNameW(hwnd, buffer, 64);
            if (length > 0 && ShellClasses.Contains(new string(buffer, 0, length)))
            {
                return 1;
            }

            GetWindowThreadProcessId(hwnd, out var pid);
            if (!_collecting.TryGetValue((int)pid, out var list))
            {
                _collecting[(int)pid] = list = new List<IntPtr>();
            }

            list.Add(hwnd);
        }
        catch
        {
            // 枚举回调里不能抛。
        }

        return 1;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial int EnumWindows(IntPtr callback, IntPtr data);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindowVisible(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetWindow(IntPtr hwnd, int command);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);

    [LibraryImport("user32.dll")]
    private static partial int GetWindowTextLengthW(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    private static partial int GetClassNameW(IntPtr hwnd, char* name, int capacity);

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int command);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
}

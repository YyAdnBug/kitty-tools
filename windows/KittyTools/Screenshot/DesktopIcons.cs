// 截图、录屏时隐藏桌面图标（PLAN-v11 F6，mac X9；设置 › 截图「截图、录屏时隐藏桌面图标」，默认关）。
// 做法：把桌面那扇图标列表（Progman / WorkerW → SHELLDLL_DefView → SysListView32 "FolderView"）ShowWindow 藏起来，
// 截完那一下 / 录完那一段再显示回来。只改这扇窗口的可见性，不碰资源管理器「显示桌面图标」那个设置（那个会写进注册表）；
// 资源管理器重启后图标自己就回来了。
// 闪退、被结束时来不及显示回来：藏之前在数据目录写一个标记文件，下次启动（RecoverAfterCrash）看到它就把图标显示回来。
// 截图和录屏可能叠在一起（录着的时候截图），按引用计数，最后一个放手才显示回来。
// ponytail: 用的是没写进文档的窗口类名（Windows 7–11 一直是这一套）；找不到时什么都不做、照常截。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static partial class DesktopIcons
{
    private const int SwHide = 0;
    private const int SwShowNa = 8;

    private static int _holds;
    private static IntPtr _hidden;

    private static string MarkerPath => Path.Combine(Paths.DataDirectory, "desktop-icons-hidden");

    /// <summary>设置开着时藏起桌面图标，返回的对象 Dispose 时显示回来；设置关着、找不到图标窗口时返回 null。</summary>
    public static IDisposable? HideIfEnabled()
        => SettingsService.Current.CaptureHideDesktopIcons ? Hide() : null;

    public static IDisposable? Hide()
    {
        if (_holds++ == 0)
        {
            var view = FindFolderView();
            if (view != IntPtr.Zero && IsWindowVisible(view))
            {
                try
                {
                    Directory.CreateDirectory(Paths.DataDirectory);
                    File.WriteAllText(MarkerPath, "1");
                }
                catch (Exception ex)
                {
                    Log.Warn($"desktop-icons.marker-failed {ex.GetType().Name}");
                }

                ShowWindow(view, SwHide);
                _hidden = view;
                // 等桌面重画完再截：DWM 合成两帧（约 33 ms）。
                for (var frame = 0; frame < 2; frame++)
                {
                    DwmFlush();
                }

                Log.Info("desktop-icons.hidden");
            }
        }

        return new Holder();
    }

    /// <summary>启动时：上次藏了图标没来得及显示回来（闪退、被结束）→ 显示回来。</summary>
    public static void RecoverAfterCrash()
    {
        if (!File.Exists(MarkerPath))
        {
            return;
        }

        var view = FindFolderView();
        if (view != IntPtr.Zero && !IsWindowVisible(view))
        {
            ShowWindow(view, SwShowNa);
            Log.Info("desktop-icons.recovered");
        }

        DeleteMarker();
    }

    /// <summary>自检（CaptureProbe）：桌面图标列表此刻是不是显示着（找不到时 null）。</summary>
    internal static bool? FolderViewVisibleForProbe()
        => FindFolderView() is var view && view != IntPtr.Zero ? IsWindowVisible(view) : null;

    private static void Release()
    {
        if (_holds == 0 || --_holds > 0)
        {
            return;
        }

        if (_hidden != IntPtr.Zero)
        {
            // 资源管理器在这期间重启过的话旧句柄已经没了，新的那扇本来就是显示着的。
            if (IsWindow(_hidden))
            {
                ShowWindow(_hidden, SwShowNa);
            }

            _hidden = IntPtr.Zero;
            Log.Info("desktop-icons.shown");
        }

        DeleteMarker();
    }

    private static void DeleteMarker()
    {
        try
        {
            File.Delete(MarkerPath);
        }
        catch (Exception ex)
        {
            Log.Warn($"desktop-icons.marker-delete-failed {ex.GetType().Name}");
        }
    }

    /// <summary>桌面图标列表：一般挂在 Progman 下；开了幻灯片壁纸等情况会挪到某一扇 WorkerW 下。</summary>
    private static IntPtr FindFolderView()
    {
        var progman = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "Progman", null);
        var defView = progman == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        var worker = IntPtr.Zero;
        while (defView == IntPtr.Zero)
        {
            worker = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null);
            if (worker == IntPtr.Zero)
            {
                return IntPtr.Zero;
            }

            defView = FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
        }

        return FindWindowEx(defView, IntPtr.Zero, "SysListView32", "FolderView");
    }

    private sealed class Holder : IDisposable
    {
        private bool _released;

        public void Dispose()
        {
            if (!_released)
            {
                _released = true;
                Release();
            }
        }
    }

    [LibraryImport("user32.dll", EntryPoint = "FindWindowExW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? className, string? title);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr window, int command);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindowVisible(IntPtr window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindow(IntPtr window);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmFlush();
}

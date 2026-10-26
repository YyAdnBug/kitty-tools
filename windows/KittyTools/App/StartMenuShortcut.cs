// 开始菜单快捷方式（PLAN-v6 第 7 批）：第一次运行时在「开始菜单 › 程序」里建 Kitty Tools.lnk，
// 指向当前 exe；更新换了目录也会改过去。只在正式版（Kitty Tools）里做，Dev 版不建。
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Shell;

namespace KittyTools;

internal static unsafe class StartMenuShortcut
{
    private static readonly Guid ShellLinkClsid = new("00021401-0000-0000-C000-000000000046");

    public static string Path
        => System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", "Kitty Tools.lnk");

    public static void Ensure()
    {
#if !DEBUG
        // Dev 版不建开始菜单项，正式版才建；Release 的探针档（KITTY_PROBE_PROFILE）也不碰用户的开始菜单。
        if (Paths.IsTestProfile)
        {
            return;
        }

        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe))
            {
                return;
            }

            var target = Path;
            if (File.Exists(target) && Shortcuts.ResolveTarget(target) is { } existing &&
                string.Equals(existing, exe, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
            IShellLinkW* link = null;
            var clsid = ShellLinkClsid;
            var iid = typeof(IShellLinkW).GUID;
            var hr = PInvoke.CoCreateInstance(
                &clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &iid, (void**)&link);
            if (hr.Failed || link is null)
            {
                Log.Warn($"shortcut.create 0x{hr.Value:X8}");
                return;
            }

            IPersistFile* persist = null;
            try
            {
                fixed (char* exePath = exe)
                fixed (char* arguments = "")
                fixed (char* icon = exe)
                fixed (char* lnk = target)
                {
                    link->SetPath(new PCWSTR(exePath));
                    link->SetArguments(new PCWSTR(arguments));
                    link->SetIconLocation(new PCWSTR(icon), 0);
                    link->SetDescription("Kitty Tools");

                    var persistIid = typeof(IPersistFile).GUID;
                    void* raw = null;
                    if (link->QueryInterface(&persistIid, &raw).Failed || raw is null)
                    {
                        return;
                    }

                    persist = (IPersistFile*)raw;
                    persist->Save(new PCWSTR(lnk), true);
                }
            }
            finally
            {
                if (persist is not null)
                {
                    persist->Release();
                }

                link->Release();
            }

            Log.Info("shortcut.created");
        }
        catch (Exception ex)
        {
            Log.Warn($"shortcut.failed {ex.GetType().Name}");
        }
#endif
    }

    public static void Remove()
    {
        try
        {
            if (File.Exists(Path))
            {
                File.Delete(Path);
                Log.Info("shortcut.removed");
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"shortcut.remove-failed {ex.GetType().Name}");
        }
    }
}

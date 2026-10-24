// 快捷方式（.lnk）的目标解析：CoCreateInstance(ShellLink) → QueryInterface(IPersistFile) → Load，
// 再 IShellLinkW.GetPath。用来把「卸载 xxx」、说明文档、网址快捷方式挡在启动器外面，
// 并把同一个程序在「所有用户」和「当前用户」下的两个快捷方式合成一条（第二版 §2 第 13 条）。
// 解析不到（比如指向 MSI 修复项的快捷方式）就返回 null，调用方退回按名字判断。
// 注意：IShellLinkW 和 IPersistFile 是两条独立的 vtable，必须 QueryInterface，不能直接转型。
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Shell;

namespace KittyTools;

internal static unsafe class Shortcuts
{
    private static readonly Guid ShellLinkClsid = new("00021401-0000-0000-C000-000000000046");

    public static string? ResolveTarget(string linkPath)
    {
        IShellLinkW* link = null;
        var clsid = ShellLinkClsid;
        var linkIid = typeof(IShellLinkW).GUID;
        var created = PInvoke.CoCreateInstance(
            &clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &linkIid, (void**)&link);
        if (created.Failed || link is null)
        {
            return null;
        }

        IPersistFile* persist = null;
        try
        {
            var persistIid = typeof(IPersistFile).GUID;
            void* raw = null;
            if (link->QueryInterface(&persistIid, &raw).Failed || raw is null)
            {
                return null;
            }

            persist = (IPersistFile*)raw;
            fixed (char* path = linkPath)
            {
                persist->Load(new PCWSTR(path), STGM.STGM_READ);
            }

            const int capacity = 1024;
            var buffer = stackalloc char[capacity];
            if (link->GetPath(buffer, capacity, null, (uint)SLGP_FLAGS.SLGP_RAWPATH).Failed)
            {
                return null;
            }

            var length = 0;
            while (length < capacity && buffer[length] != '\0')
            {
                length++;
            }

            return length == 0 ? null : new string(buffer, 0, length);
        }
        finally
        {
            if (persist is not null)
            {
                persist->Release();
            }

            link->Release();
        }
    }
}

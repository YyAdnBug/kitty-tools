// 安装和卸载共用的系统操作：叫开着的程序退出（S5）、开始菜单快捷方式、开机启动、凭据、回收站、「设置 › 应用」里的登记。
// 快捷方式、开机启动、凭据的写法照 App 的 App/StartMenuShortcut.cs、App/Autostart.cs、Storage/Credentials.cs 抄了一份
// （PLAN-setup §3 二选一，抄比抽共享文件改动小）：那三个文件改了位置或写法，这里要一起改。
// 名字全从 SetupNames 来：KITTY_SETUP_TEST_KEY 下是测试用的那一套，碰不到用户真实的注册表项和凭据。
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using KittyTools.Core;
using Microsoft.Win32;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Shell;

namespace KittyTools.Setup;

internal static unsafe partial class SystemSteps
{
    private const string QuitCommand = "quit";
    private const int QuitWaitMs = 10_000;
    private const int CredentialTypeGeneric = 1;

    private static readonly Guid ShellLinkClsid = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid DownloadsFolderId = new("374DE290-123F-4565-9164-39C4925E467B");

    /// <summary>后台线程先进 COM 再建快捷方式（主线程是 STA，已经初始化过）。</summary>
    public static void InitializeCom() => PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED);

    /// <summary>
    /// S5：程序开着（互斥量还在）就从单实例管道发 quit，最多等 10 s 看互斥量放没放掉。返回 true = 现在没在跑了。
    /// 不按进程名结束任何进程：老版本不认 quit，就等用户自己从托盘退出。
    /// </summary>
    public static bool QuitRunningApp(SetupNames names)
    {
        if (!IsRunning(names))
        {
            return true;
        }

        SetupLog.Write("app.running send-quit");
        try
        {
            using var pipe = new NamedPipeClientStream(".", names.PipeName, PipeDirection.Out);
            pipe.Connect(2000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            writer.WriteLine(QuitCommand);
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or UnauthorizedAccessException)
        {
            SetupLog.Write($"app.quit-pipe-failed {ex.GetType().Name}");
        }

        var deadline = Environment.TickCount64 + QuitWaitMs;
        while (Environment.TickCount64 < deadline)
        {
            Thread.Sleep(200);
            if (!IsRunning(names))
            {
                SetupLog.Write("app.quit-ok");
                return true;
            }
        }

        SetupLog.Write("app.still-running");
        return false;
    }

    private static bool IsRunning(SetupNames names)
    {
        try
        {
            if (!Mutex.TryOpenExisting(names.MutexName, out var mutex))
            {
                return false;
            }

            // 拿着句柄互斥量就不会消失，查完马上放。
            mutex.Dispose();
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return true;
        }
    }

    public static string ShortcutPath(SetupNames names)
        => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", names.ShortcutFile);

    /// <summary>开始菜单 › 程序 › Kitty Tools.lnk，指向 exe（和 App 的 StartMenuShortcut.Ensure 一样）。</summary>
    public static void CreateShortcut(SetupNames names, string exe)
    {
        var target = ShortcutPath(names);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        IShellLinkW* link = null;
        var clsid = ShellLinkClsid;
        var iid = typeof(IShellLinkW).GUID;
        var hr = PInvoke.CoCreateInstance(&clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &iid, (void**)&link);
        if (hr.Failed || link is null)
        {
            SetupLog.Write($"shortcut.create 0x{hr.Value:X8}");
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

        SetupLog.Write("shortcut.created");
    }

    public static void RemoveShortcut(SetupNames names)
    {
        var path = ShortcutPath(names);
        if (File.Exists(path))
        {
            File.Delete(path);
            SetupLog.Write("shortcut.removed");
        }
    }

    /// <summary>HKCU\…\Run 里的值（和 App 的 Autostart.Set 一样：exe 的完整路径，带引号）。</summary>
    public static void SetAutostart(SetupNames names, string exe, bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(SetupRules.RunKey, writable: true)
                        ?? throw new IOException("Run 键打不开");
        if (enabled)
        {
            key.SetValue(names.RunValue, $"\"{exe}\"", RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(names.RunValue, throwOnMissingValue: false);
        }
    }

    /// <summary>卸载：开机启动值指向这个安装目录里的 exe 才删（另一份解压版的不动）。</summary>
    public static void RemoveAutostart(SetupNames names, string exe)
    {
        using var key = Registry.CurrentUser.OpenSubKey(SetupRules.RunKey, writable: true);
        if (key?.GetValue(names.RunValue) is string value && SetupRules.SamePath(value.Trim().Trim('"'), exe))
        {
            key.DeleteValue(names.RunValue, throwOnMissingValue: false);
            SetupLog.Write("autostart.removed");
        }
    }

    private static string UninstallKeyPath(SetupNames names) => SetupRules.UninstallRoot + "\\" + names.UninstallKey;

    /// <summary>「设置 › 应用」里原来登记的位置和版本；没装过返回 (null, null)。</summary>
    public static (string? Dir, string? Version) ReadRegistration(SetupNames names)
    {
        using var key = Registry.CurrentUser.OpenSubKey(UninstallKeyPath(names));
        return (key?.GetValue("InstallLocation") as string, key?.GetValue("DisplayVersion") as string);
    }

    public static void Register(SetupNames names, string dir, string version)
    {
        using var key = Registry.CurrentUser.CreateSubKey(UninstallKeyPath(names), writable: true)
                        ?? throw new IOException("Uninstall 键打不开");
        foreach (var value in SetupRules.UninstallValues(dir, version, SetupRules.DirectorySizeKb(dir), DateTime.Now))
        {
            if (value.Number is { } number)
            {
                key.SetValue(value.Name, number, RegistryValueKind.DWord);
            }
            else
            {
                key.SetValue(value.Name, value.Text ?? string.Empty, RegistryValueKind.String);
            }
        }

        SetupLog.Write("registry.registered");
    }

    /// <summary>登记的就是这个目录（或者登记已经没了）才删，别把另一处的登记删掉。</summary>
    public static void Unregister(SetupNames names, string dir)
    {
        var (registered, _) = ReadRegistration(names);
        if (registered is null || SetupRules.SamePath(registered, dir))
        {
            Registry.CurrentUser.DeleteSubKeyTree(UninstallKeyPath(names), throwOnMissingSubKey: false);
            SetupLog.Write("registry.removed");
        }
    }

    /// <summary>凭据管理器里前缀是 prefix 的全部删掉（和 App 的 Credentials.DeleteAll 一样）；返回删了几条。</summary>
    public static int DeleteCredentials(string prefix)
    {
        var deleted = 0;
        if (!CredEnumerate(prefix + "*", 0, out var count, out var list) || list == IntPtr.Zero)
        {
            return 0;
        }

        try
        {
            for (var index = 0; index < count; index++)
            {
                var credential = (Credential*)((IntPtr*)list)[index];
                if (credential is not null && credential->TargetName != IntPtr.Zero &&
                    CredDelete(Marshal.PtrToStringUni(credential->TargetName) ?? string.Empty, CredentialTypeGeneric, 0))
                {
                    deleted++;
                }
            }
        }
        finally
        {
            CredFree(list);
        }

        return deleted;
    }

    /// <summary>整个文件夹挪进回收站，不弹任何框（SHFileOperation + FOF_SILENT / NOERRORUI）；返回它是不是真的不在了。</summary>
    public static bool Recycle(string dir)
    {
        if (!Directory.Exists(dir))
        {
            return true;
        }

        const uint Delete = 0x0003;
        const ushort Quietly = 0x0004 | 0x0010 | 0x0040 | 0x0400; // SILENT | NOCONFIRMATION | ALLOWUNDO | NOERRORUI
        fixed (char* from = dir + "\0\0")
        {
            var operation = new FileOperation { Func = Delete, From = from, Flags = Quietly };
            var result = SHFileOperation(&operation);
            if (result != 0 || operation.AnyOperationsAborted != 0)
            {
                SetupLog.Write($"data.recycle 0x{result:X} aborted={operation.AnyOperationsAborted}");
            }
        }

        return !Directory.Exists(dir);
    }

    /// <summary>删整个文件夹。刚退出的程序可能还没把文件放开，失败了隔 300 ms 再试，最多 3 s。</summary>
    public static bool DeleteDirectory(string dir)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                if (Directory.Exists(dir))
                {
                    Directory.Delete(dir, recursive: true);
                }

                return true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                if (attempt == 9)
                {
                    SetupLog.Write($"dir.delete-failed {ex.GetType().Name}");
                }

                Thread.Sleep(300);
            }
        }

        return false;
    }

    /// <summary>只删 dir 里列出来的这些文件（相对路径），再把删空了的子文件夹和 dir 本身收掉。</summary>
    public static void DeleteFiles(string dir, IEnumerable<string> relativeFiles)
    {
        foreach (var relative in relativeFiles)
        {
            try
            {
                File.Delete(Path.Combine(dir, relative));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                SetupLog.Write($"file.delete-failed {ex.GetType().Name}");
            }
        }

        foreach (var sub in Directory.EnumerateDirectories(dir, "*", SearchOption.AllDirectories).OrderByDescending(path => path.Length))
        {
            RemoveIfEmpty(sub);
        }

        RemoveIfEmpty(dir);
    }

    public static void RemoveIfEmpty(string dir)
    {
        try
        {
            if (Directory.Exists(dir) && !Directory.EnumerateFileSystemEntries(dir).Any())
            {
                Directory.Delete(dir);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 收不掉就留着，不影响结果。
        }
    }

    /// <summary>
    /// 登记「重启时删」。系统只让管理员这么登记，普通权限下会失败（只记日志）：
    /// ponytail: 临时那份卸载程序（几 MB）就留在 %TEMP%，下次安装 / 卸载时 CleanStaleCopies 顺手清；要当场删得另起一个进程等我们退出。
    /// </summary>
    public static void DeleteAfterReboot(string path)
    {
        if (!MoveFileEx(path, null, 0x0004))
        {
            SetupLog.Write($"temp.delay-delete-failed {Marshal.GetLastPInvokeError()}");
        }
    }

    /// <summary>「现在打开」。测试名下给 App 带上同名的 KITTY_PROBE_PROFILE（它的互斥量、数据目录才对得上）。</summary>
    public static void Launch(SetupNames names, string exe)
    {
        try
        {
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
            if (names.ProbeProfile is { } profile)
            {
                start.Environment["KITTY_PROBE_PROFILE"] = profile;
            }

            Process.Start(start)?.Dispose();
            SetupLog.Write("app.launched");
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException)
        {
            SetupLog.Write($"app.launch-failed {ex.GetType().Name}");
        }
    }

    /// <summary>§2.2 的禁止名单：这台电脑上 Windows、Program Files 那几个文件夹，和用户主目录、桌面、文档、下载、图片、音乐、视频。</summary>
    public static SetupFolders Folders()
    {
        static string Special(Environment.SpecialFolder folder) => Environment.GetFolderPath(folder);
        string?[] system =
        [
            Special(Environment.SpecialFolder.Windows),
            Special(Environment.SpecialFolder.ProgramFiles),
            Special(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetEnvironmentVariable("ProgramW6432"),
            Environment.GetEnvironmentVariable("ProgramFiles(Arm)"),
        ];
        string?[] personal =
        [
            Special(Environment.SpecialFolder.UserProfile),
            Special(Environment.SpecialFolder.DesktopDirectory),
            Special(Environment.SpecialFolder.MyDocuments),
            KnownFolder(DownloadsFolderId),
            Special(Environment.SpecialFolder.MyPictures),
            Special(Environment.SpecialFolder.MyMusic),
            Special(Environment.SpecialFolder.MyVideos),
        ];
        return new SetupFolders(
            system.OfType<string>().Where(path => path.Length > 0).ToList(),
            personal.OfType<string>().Where(path => path.Length > 0).ToList());
    }

    private static string? KnownFolder(Guid id)
    {
        char* path = null;
        try
        {
            return SHGetKnownFolderPath(&id, 0, 0, &path) >= 0 && path is not null ? new string(path) : null;
        }
        finally
        {
            if (path is not null)
            {
                Marshal.FreeCoTaskMem((nint)path);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    /// <summary>SHFILEOPSTRUCTW：64 位下是自然对齐（shellapi.h 只在 32 位下 pack(1)），56 字节。</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct FileOperation
    {
        public nint Hwnd;
        public uint Func;
        public char* From;
        public char* To;
        public ushort Flags;
        public int AnyOperationsAborted;
        public nint NameMappings;
        public char* ProgressTitle;
    }

    [LibraryImport("advapi32.dll", EntryPoint = "CredDeleteW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredDelete(string target, int type, uint flags);

    [LibraryImport("advapi32.dll", EntryPoint = "CredEnumerateW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredEnumerate(string filter, uint flags, out int count, out IntPtr list);

    [LibraryImport("advapi32.dll", EntryPoint = "CredFree")]
    private static partial void CredFree(IntPtr credential);

    [LibraryImport("shell32.dll", EntryPoint = "SHFileOperationW")]
    private static partial int SHFileOperation(FileOperation* operation);

    [LibraryImport("shell32.dll", EntryPoint = "SHGetKnownFolderPath")]
    private static partial int SHGetKnownFolderPath(Guid* id, uint flags, nint token, char** path);

    [LibraryImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MoveFileEx(string existing, string? replacement, uint flags);
}

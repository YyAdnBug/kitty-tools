// 启动器文件搜索要知道的 Windows 搜索状态（PLAN-v25 F8、F10）：服务（WSearch）开没开、索引目录在干什么（空闲 / 暂停 / 正在建）、
// 还剩多少项没建、已编入多少项、常用文件夹和每块本地固定盘在不在索引里。读一次几到几十毫秒，缓存 60 秒，线程池里调。
// 判断该说什么在 Core 的 FileSearchHints（纯函数）；这里只读原值。读不出来的一律当「不知道」，不能当成「没进索引」。
//
// COM 照 OleDbFileSearch 的写法用函数指针按 vtable 调（AOT 不能用运行期 COM 互操作）。vtable 序号是 Windows SDK searchapi.h 里
// 接口方法的声明顺序（IUnknown 占 0–2）。**审查方在 Mac 上照 SDK 的声明写的、没对着头文件核过**——在 Windows 上先打开
// `Include\<版本>\um\searchapi.h` 对一遍下面几个常量（数错了会调到别的方法上、可能直接崩），再跑 --file-search-status。
//
// F10「启用 Windows 搜索」：以管理员身份（UAC）跑 sc.exe 把启动类型改回「自动（延迟启动）」并启动；用户点「否」什么都不变。
using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.System.Com;

namespace KittyTools;

internal static unsafe partial class SearchIndexStatus
{
    private static readonly Guid ClsidSearchManager = new("7D096C5F-AC08-4F1F-BEB7-5C22C517CE39");
    private static readonly Guid IidSearchManager = new("AB310581-AC80-11D1-8DF3-00C04FB6EF69");

    // searchapi.h 声明顺序（见文件头：Windows 上核对）
    private const int SearchManagerGetCatalog = 10;
    private const int CatalogGetCatalogStatus = 6;
    private const int CatalogNumberOfItems = 15;
    private const int CatalogNumberOfItemsToIndex = 16;
    private const int CatalogGetCrawlScopeManager = 28;
    private const int ScopeHasChildScopeRule = 12;
    private const int ScopeIncludedInCrawlScope = 13;

    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryConfig = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const uint ServiceRunning = 4;
    private const uint ServiceDisabled = 4;
    private const int ErrorServiceDoesNotExist = 1060;
    private const int ErrorCancelled = 1223;

    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(60);
    private static readonly object Gate = new();
    private static FileIndexStatus? _cached;
    private static long _cachedAt;

    /// <summary>缓存里的（60 秒内读过的），没有就现读。线程池里调。</summary>
    public static FileIndexStatus Get()
    {
        lock (Gate)
        {
            if (_cached is not null && Environment.TickCount64 - _cachedAt < CacheFor.TotalMilliseconds)
            {
                return _cached;
            }
        }

        var status = Read();
        lock (Gate)
        {
            _cached = status;
            _cachedAt = Environment.TickCount64;
        }

        return status;
    }

    /// <summary>扔掉缓存（启用了服务之后、设置页每次打开时）。</summary>
    public static void Forget()
    {
        lock (Gate)
        {
            _cached = null;
        }
    }

    private static FileIndexStatus Read()
    {
        var started = Environment.TickCount64;
        var service = ReadService();
        var folders = FileSearch.KnownFolders();
        var drives = DriveInfo.GetDrives()
            .Where(drive => drive.DriveType == DriveType.Fixed && drive.IsReady)
            .Select(drive => drive.RootDirectory.FullName)
            .ToList();
        var catalog = service == IndexService.Running ? ReadCatalog(folders, drives) : null;
        var status = new FileIndexStatus(
            service,
            catalog?.Status ?? -1,
            catalog?.Reason ?? -1,
            catalog?.Pending ?? -1,
            catalog?.Items ?? -1,
            catalog?.UncoveredDrives ?? Array.Empty<string>(),
            catalog?.UncoveredFolders ?? Array.Empty<string>());
        Log.Info(FileSearchHints.LogLine(status) + $" ms={Environment.TickCount64 - started}");
        return status;
    }

    private sealed record Catalog(int Status, int Reason, int Pending, int Items, IReadOnlyList<string> UncoveredDrives, IReadOnlyList<string> UncoveredFolders);

    // ---- 服务

    private static IndexService ReadService()
    {
        var manager = OpenSCManagerW(null, null, ScManagerConnect);
        if (manager == IntPtr.Zero)
        {
            return IndexService.Unknown;
        }

        try
        {
            var service = OpenServiceW(manager, "WSearch", ServiceQueryConfig | ServiceQueryStatus);
            if (service == IntPtr.Zero)
            {
                return Marshal.GetLastPInvokeError() == ErrorServiceDoesNotExist ? IndexService.Missing : IndexService.Unknown;
            }

            try
            {
                if (!QueryServiceStatus(service, out var status))
                {
                    return IndexService.Unknown;
                }

                if (status.CurrentState == ServiceRunning)
                {
                    return IndexService.Running;
                }

                return StartType(service) == ServiceDisabled ? IndexService.Disabled : IndexService.Stopped;
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(manager);
        }
    }

    /// <summary>QUERY_SERVICE_CONFIGW.dwStartType（偏移 4）；读不出来是 uint.MaxValue。</summary>
    private static uint StartType(IntPtr service)
    {
        QueryServiceConfigW(service, null, 0, out var needed);
        if (needed < 8 || needed > 64 * 1024)
        {
            return uint.MaxValue;
        }

        var buffer = new byte[needed];
        fixed (byte* data = buffer)
        {
            if (!QueryServiceConfigW(service, data, needed, out _))
            {
                return uint.MaxValue;
            }
        }

        return BinaryPrimitives.ReadUInt32LittleEndian(buffer.AsSpan(4));
    }

    // ---- 索引目录

    private static Catalog? ReadCatalog(IReadOnlyList<string> folders, IReadOnlyList<string> drives)
    {
        var comInitialized = false;
        void* manager = null;
        void* catalog = null;
        void* scope = null;
        try
        {
            comInitialized = PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED).Succeeded;
            var clsid = ClsidSearchManager;
            var iid = IidSearchManager;
            var hr = PInvoke.CoCreateInstance(&clsid, null, CLSCTX.CLSCTX_LOCAL_SERVER | CLSCTX.CLSCTX_INPROC_SERVER, &iid, &manager);
            if (hr.Failed || manager is null)
            {
                Log.Warn($"files.status-manager 0x{hr.Value:X8}");
                return null;
            }

            fixed (char* name = "SystemIndex")
            {
                var getCatalog = (delegate* unmanaged[Stdcall]<void*, char*, void**, int>)(*(void***)manager)[SearchManagerGetCatalog];
                if (getCatalog(manager, name, &catalog) < 0 || catalog is null)
                {
                    Log.Warn("files.status-catalog");
                    return null;
                }
            }

            var vtable = *(void***)catalog;
            int status = -1, reason = -1;
            if (((delegate* unmanaged[Stdcall]<void*, int*, int*, int>)vtable[CatalogGetCatalogStatus])(catalog, &status, &reason) < 0)
            {
                status = reason = -1;
            }

            int items = -1;
            if (((delegate* unmanaged[Stdcall]<void*, int*, int>)vtable[CatalogNumberOfItems])(catalog, &items) < 0)
            {
                items = -1;
            }

            int incremental = 0, notifications = 0, priority = 0;
            var pending = ((delegate* unmanaged[Stdcall]<void*, int*, int*, int*, int>)vtable[CatalogNumberOfItemsToIndex])(
                catalog, &incremental, &notifications, &priority) < 0
                ? -1
                : Math.Max(0, incremental) + Math.Max(0, notifications) + Math.Max(0, priority);

            var uncoveredDrives = new List<string>();
            var uncoveredFolders = new List<string>();
            if (((delegate* unmanaged[Stdcall]<void*, void**, int>)vtable[CatalogGetCrawlScopeManager])(catalog, &scope) >= 0 && scope is not null)
            {
                foreach (var folder in folders)
                {
                    if (Included(scope, folder, partialCounts: false) == false)
                    {
                        uncoveredFolders.Add(folder);
                    }
                }

                foreach (var drive in drives)
                {
                    // 盘根不在、底下也没有收进去的位置，才算这块盘不在索引里（经典模式的 C: 只收了 C:\Users，算在）
                    if (Included(scope, drive, partialCounts: true) == false)
                    {
                        uncoveredDrives.Add(drive.TrimEnd('\\'));
                    }
                }
            }

            return new Catalog(status, reason, pending, items, uncoveredDrives, uncoveredFolders);
        }
        catch (Exception ex)
        {
            Log.Warn($"files.status-failed {ex.GetType().Name}");
            return null;
        }
        finally
        {
            if (scope is not null)
            {
                Release(scope);
            }

            if (catalog is not null)
            {
                Release(catalog);
            }

            if (manager is not null)
            {
                Release(manager);
            }

            if (comInitialized)
            {
                PInvoke.CoUninitialize();
            }
        }
    }

    /// <summary>在不在索引里：true / false；问不出来是 null。partialCounts：底下有收进去的位置也算在。</summary>
    private static bool? Included(void* scope, string folder, bool partialCounts)
    {
        var vtable = *(void***)scope;
        fixed (char* url = FileSearchFilter.CrawlUrl(folder))
        {
            int included = 0;
            if (((delegate* unmanaged[Stdcall]<void*, char*, int*, int>)vtable[ScopeIncludedInCrawlScope])(scope, url, &included) < 0)
            {
                return null;
            }

            if (included != 0 || !partialCounts)
            {
                return included != 0;
            }

            int child = 0;
            if (((delegate* unmanaged[Stdcall]<void*, char*, int*, int>)vtable[ScopeHasChildScopeRule])(scope, url, &child) < 0)
            {
                return null;
            }

            return child != 0;
        }
    }

    private static void Release(void* self)
        => ((delegate* unmanaged[Stdcall]<void*, uint>)(*(void***)self)[2])(self);

    // ---- F10 启用服务

    /// <summary>
    /// 以管理员身份把 WSearch 改回「自动（延迟启动）」并启动（系统弹 UAC）。true = 服务起来了；false = 没成；
    /// null = 用户在 UAC 里点了「否」（不算失败、不弹错）。UI 线程调（只在等的时候让出去）。
    /// </summary>
    public static async Task<bool?> EnableServiceAsync()
    {
        var system = Environment.SystemDirectory;
        var sc = Path.Combine(system, "sc.exe");
        var info = new ProcessStartInfo(Path.Combine(system, "cmd.exe"),
            $"/d /s /c \"\"{sc}\" config WSearch start= delayed-auto && \"{sc}\" start WSearch\"")
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try
        {
            using (var process = Process.Start(info))
            {
                if (process is null)
                {
                    return false;
                }

                await process.WaitForExitAsync();
            }
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == ErrorCancelled)
        {
            return null;
        }
        catch (Exception ex)
        {
            Log.Warn($"files.enable-service-failed {ex.GetType().Name}");
            return false;
        }

        // sc start 发出去就返回（还在 START_PENDING）；已经在跑时它返回 1056、退出码不是 0——所以不看退出码，等几下看服务本身
        Forget();
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (ReadService() == IndexService.Running)
            {
                Log.Info("files.enable-service ok");
                return true;
            }

            await Task.Delay(500);
        }

        Log.Warn("files.enable-service not-running");
        return false;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
    }

    [LibraryImport("advapi32.dll", EntryPoint = "OpenSCManagerW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr OpenSCManagerW(string? machine, string? database, uint access);

    [LibraryImport("advapi32.dll", EntryPoint = "OpenServiceW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr OpenServiceW(IntPtr manager, string name, uint access);

    [LibraryImport("advapi32.dll", EntryPoint = "QueryServiceStatus", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryServiceStatus(IntPtr service, out ServiceStatus status);

    [LibraryImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryServiceConfigW(IntPtr service, byte* config, uint size, out uint needed);

    [LibraryImport("advapi32.dll", EntryPoint = "CloseServiceHandle")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseServiceHandle(IntPtr handle);
}

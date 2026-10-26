// 文件搜索走 Windows Search 的 OLE DB 提供程序（PLAN-v6 第 4 批，取代 880 ms 的 WinRT StorageFile 查询）。
//
// 直连 Search.CollatorDSO + SYSTEMINDEX，只查两件事：System.ItemUrl（真实路径）和文件名，
// 由 FileSearchSql 生成 SQL，结果交给启动器再打分。
//
// 两个坑（2026-10-26 用独立探针试出来的）：
// 1. **x64 上 DBBINDING 的偏移 / 长度字段是 8 字节**（DBORDINAL / DBBYTEOFFSET / DBLENGTH 都是 ULONGLONG），
//    按 4 字节写结构体会让 CreateAccessor 返回 DB_E_BADBINDINFO（0x80040E46）或直接崩；
//    obLength / obStatus 也要按 8 字节对齐（value 24 → length 24 → status 32）。
// 2. **IRowset 不继承 IAccessor**（oledb.h 里是 IRowset : IUnknown），必须单独 QueryInterface(IAccessor)。
//    把两个接口拼成一张 vtable 会把 CreateAccessor 调到 AddRefRows 上。
//
// COM 一律用函数指针按 vtable 调（AOT 不能用运行期 COM 互操作）；索引服务的查询在毫秒级。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;

namespace KittyTools;

internal static unsafe class OleDbFileSearch
{
    private static readonly Guid ClsidSearchCollator =
        new("9E175B8B-F52A-11D8-B9A5-505054503030");

    private static readonly Guid IidDbInitialize =
        new("0C733A8B-2A1C-11CE-ADE5-00AA0044773D");

    private static readonly Guid IidDbCreateSession =
        new("0C733A5D-2A1C-11CE-ADE5-00AA0044773D");

    private static readonly Guid IidDbCreateCommand =
        new("0C733A1D-2A1C-11CE-ADE5-00AA0044773D");

    private static readonly Guid IidCommandText =
        new("0C733A27-2A1C-11CE-ADE5-00AA0044773D");

    private static readonly Guid IidRowset =
        new("0C733A7C-2A1C-11CE-ADE5-00AA0044773D");

    private static readonly Guid IidAccessor =
        new("0C733A8C-2A1C-11CE-ADE5-00AA0044773D");

    private static readonly Guid DbGuidDbSql =
        new("C8B521FB-5CF3-11CE-ADE5-00AA0044773D");

    // 一列：System.ItemUrl。行布局 value 24 + length 8 + status 8 = 40。
    private const ulong ValueSize = 24;
    private const ulong LengthOffset = 24;
    private const ulong StatusOffset = 32;
    private const ulong RowSize = 40;

    private const ushort DbtVariant = 12;
    private const uint DbAccessorRowData = 2;
    private const uint DbPartValue = 1;
    private const uint DbPartLength = 2;
    private const uint DbPartStatus = 4;

    /// <summary>
    /// 查索引。成功返回路径（可能为空）；索引服务不可用 / SQL 出错返回 null，调用方退回 WinRT 查询。
    /// 这个方法是同步的，调用方应放到线程池上。
    /// </summary>
    public static List<string>? Search(IReadOnlyList<string> tokens, IReadOnlyList<string> roots)
    {
        var sql = FileSearchSql.Build(tokens, roots);
        if (sql.Length == 0)
        {
            return null;
        }

        var comInitialized = false;
        void* dataSource = null;
        void* session = null;
        void* command = null;
        void* rowset = null;
        void* accessor = null;
        void* accessorHandle = null;
        var started = Environment.TickCount64;
        try
        {
            var coInit = PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED);
            comInitialized = coInit.Succeeded;

            var clsid = ClsidSearchCollator;
            var iidInitialize = IidDbInitialize;
            var hr = PInvoke.CoCreateInstance(
                &clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &iidInitialize, &dataSource);
            if (hr.Failed || dataSource is null)
            {
                Log.Warn($"files.oledb-create 0x{hr.Value:X8}");
                return null;
            }

            if (Initialize(dataSource) < 0)
            {
                Log.Warn("files.oledb-init");
                return null;
            }

            if (QueryInterface(dataSource, IidDbCreateSession, out session) < 0 || session is null ||
                CreateSession(session, IidDbCreateCommand, out var createdSession) < 0 || createdSession is null)
            {
                Log.Warn("files.oledb-session");
                return null;
            }

            session = createdSession;
            if (CreateCommand(session, IidCommandText, out command) < 0 || command is null)
            {
                Log.Warn("files.oledb-command");
                return null;
            }

            if (!SetCommandText(command, sql))
            {
                Log.Warn("files.oledb-settext");
                return null;
            }

            if (Execute(command, out rowset) < 0 || rowset is null)
            {
                Log.Warn("files.oledb-execute");
                return null;
            }

            if (QueryInterface(rowset, IidAccessor, out accessor) < 0 || accessor is null)
            {
                Log.Warn("files.oledb-accessor-qi");
                return null;
            }

            var binding = new DBBinding
            {
                iOrdinal = 1,
                obValue = 0,
                obLength = LengthOffset,
                obStatus = StatusOffset,
                dwPart = DbPartValue | DbPartLength | DbPartStatus,
                cbMaxLen = ValueSize,
                wType = DbtVariant,
            };
            uint status = 0;
            var created = CreateAccessor(accessor, &binding, 1, RowSize, out accessorHandle, &status);
            if (created < 0 || accessorHandle is null)
            {
                Log.Warn($"files.oledb-createaccessor 0x{created:X8} status={status}");
                return null;
            }

            var results = new List<string>();
            var data = stackalloc byte[(int)RowSize];
            while (results.Count < FileSearchSql.DefaultLimit)
            {
                var next = GetNextRows(rowset, FileSearchSql.DefaultLimit, out var obtained, out var rows);
                if (rows is null || obtained == 0)
                {
                    break;
                }

                try
                {
                    for (ulong index = 0; index < obtained; index++)
                    {
                        var row = ((void**)rows)[index];
                        if (GetData(rowset, row, accessorHandle, data) < 0)
                        {
                            continue;
                        }

                        var rowStatus = *(uint*)(data + StatusOffset);
                        if (rowStatus != 0)
                        {
                            continue;
                        }

                        var path = FileSearchSql.LocalPathFromItemUrl(ReadVariantString(data));
                        if (!string.IsNullOrWhiteSpace(path))
                        {
                            results.Add(path);
                        }
                    }
                }
                finally
                {
                    ReleaseRows(rowset, obtained, rows);
                    PInvoke.CoTaskMemFree(rows);
                }

                if (next != 0)
                {
                    break;
                }
            }

            Log.Info($"files.oledb hits={results.Count} ms={Environment.TickCount64 - started}");
            return results;
        }
        catch (Exception ex)
        {
            Log.Warn($"files.oledb-failed {ex.GetType().Name}");
            return null;
        }
        finally
        {
            if (accessorHandle is not null && accessor is not null)
            {
                ReleaseAccessor(accessor, accessorHandle);
            }

            if (accessor is not null)
            {
                Release(accessor);
            }

            if (rowset is not null)
            {
                Release(rowset);
            }

            if (command is not null)
            {
                Release(command);
            }

            if (session is not null)
            {
                Release(session);
            }

            if (dataSource is not null)
            {
                Release(dataSource);
            }

            if (comInitialized)
            {
                PInvoke.CoUninitialize();
            }
        }
    }

    private static string? ReadVariantString(byte* data)
    {
        var vt = *(ushort*)data;
        var value = *(IntPtr*)(data + 8);
        if (vt == 8 && value != IntPtr.Zero) // VT_BSTR
        {
            var bstr = new BSTR(value);
            var text = bstr.ToString();
            PInvoke.SysFreeString(bstr);
            return text;
        }

        if (vt == 31 && value != IntPtr.Zero) // VT_LPWSTR（个别列的变体）
        {
            return Marshal.PtrToStringUni(value);
        }

        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DBBinding
    {
        public ulong iOrdinal;
        public ulong obValue;
        public ulong obLength;
        public ulong obStatus;
        public IntPtr pTypeInfo;
        public IntPtr pObject;
        public IntPtr pBindExt;
        public uint dwPart;
        public uint dwMemOwner;
        public uint eParamIO;
        public ulong cbMaxLen;
        public uint dwFlags;
        public ushort wType;
        public byte bPrecision;
        public byte bScale;
    }

    private static int Initialize(void* self)
        => ((delegate* unmanaged[Stdcall]<void*, int>)(*(void***)self)[3])(self);

    private static int QueryInterface(void* self, Guid iid, out void* result)
    {
        void* local = null;
        var hr = ((delegate* unmanaged[Stdcall]<void*, Guid*, void**, int>)(*(void***)self)[0])(self, &iid, &local);
        result = local;
        return hr;
    }

    private static void Release(void* self)
        => ((delegate* unmanaged[Stdcall]<void*, uint>)(*(void***)self)[2])(self);

    private static int CreateSession(void* self, Guid iid, out void* result)
    {
        void* local = null;
        var hr = ((delegate* unmanaged[Stdcall]<void*, void*, Guid*, void**, int>)(*(void***)self)[3])(
            self, null, &iid, &local);
        result = local;
        return hr;
    }

    private static int CreateCommand(void* self, Guid iid, out void* result)
    {
        void* local = null;
        var hr = ((delegate* unmanaged[Stdcall]<void*, void*, Guid*, void**, int>)(*(void***)self)[3])(
            self, null, &iid, &local);
        result = local;
        return hr;
    }

    private static bool SetCommandText(void* self, string sql)
    {
        fixed (char* text = sql)
        {
            var dialect = DbGuidDbSql;
            return ((delegate* unmanaged[Stdcall]<void*, Guid*, char*, int>)(*(void***)self)[7])(
                self, &dialect, text) >= 0;
        }
    }

    private static int Execute(void* self, out void* result)
    {
        void* local = null;
        var iid = IidRowset;
        var hr = ((delegate* unmanaged[Stdcall]<void*, void*, Guid*, void*, void*, void**, int>)(*(void***)self)[4])(
            self, null, &iid, null, null, &local);
        result = local;
        return hr;
    }

    private static int CreateAccessor(
        void* self, DBBinding* bindings, ulong count, ulong rowSize, out void* handle, uint* status)
    {
        void* local = null;
        var hr = ((delegate* unmanaged[Stdcall]<void*, uint, ulong, DBBinding*, ulong, void**, uint*, int>)
            (*(void***)self)[4])(self, DbAccessorRowData, count, bindings, rowSize, &local, status);
        handle = local;
        return hr;
    }

    private static void ReleaseAccessor(void* self, void* handle)
        => ((delegate* unmanaged[Stdcall]<void*, void*, uint*, int>)(*(void***)self)[6])(self, handle, null);

    private static int GetNextRows(void* self, int count, out ulong obtained, out void* rows)
    {
        ulong localObtained = 0;
        void* localRows = null;
        var hr = ((delegate* unmanaged[Stdcall]<void*, void*, int, int, ulong*, void**, int>)(*(void***)self)[5])(
            self, null, 0, count, &localObtained, &localRows);
        obtained = localObtained;
        rows = localRows;
        return hr;
    }

    private static int GetData(void* self, void* row, void* accessor, byte* data)
        => ((delegate* unmanaged[Stdcall]<void*, void*, void*, void*, int>)(*(void***)self)[4])(
            self, row, accessor, data);

    private static void ReleaseRows(void* self, ulong count, void* rows)
        => ((delegate* unmanaged[Stdcall]<void*, ulong, void**, void*, void*, void*, int>)(*(void***)self)[6])(
            self, count, &rows, null, null, null);
}

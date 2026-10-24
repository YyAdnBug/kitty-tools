// 系统自带的 winsqlite3.dll：只用到的十来个函数，全部 [LibraryImport]（AOT 可用）。
// 连接只在 UI 线程用（同 mac 版），所以这里不做线程安全。
// 字符串一律 UTF-8；绑定的文本 / 数据都让 SQLite 自己拷一份（SQLITE_TRANSIENT）。
using System.Runtime.InteropServices;
using System.Text;

namespace KittyTools.Infrastructure;

internal sealed unsafe partial class SqliteConnection : IDisposable
{
    private const int Ok = 0;
    private const int Row = 100;
    private const int Done = 101;
    private const int OpenReadWrite = 0x00000002;
    private const int OpenCreate = 0x00000004;
    private const int OpenFullMutex = 0x00010000;

    private IntPtr _db;

    public SqliteConnection(string path)
    {
        var bytes = Encoding.UTF8.GetBytes(path + "\0");
        IntPtr db;
        int result;
        fixed (byte* fileName = bytes)
        {
            result = Sqlite3OpenV2(fileName, &db, OpenReadWrite | OpenCreate | OpenFullMutex, null);
        }

        if (result != Ok || db == IntPtr.Zero)
        {
            var message = db == IntPtr.Zero ? "打不开数据库" : MessageOf(db);
            if (db != IntPtr.Zero)
            {
                Sqlite3CloseV2(db);
            }

            throw new SqliteException(result, message);
        }

        _db = db;
        Execute("PRAGMA busy_timeout = 5000;");
        Execute("PRAGMA journal_mode = WAL;");
        Execute("PRAGMA synchronous = NORMAL;");
        Execute("PRAGMA foreign_keys = ON;");
    }

    public long LastInsertRowId => Sqlite3LastInsertRowId(_db);

    public int Changes => Sqlite3Changes(_db);

    public SqliteStatement Prepare(string sql)
    {
        var bytes = Encoding.UTF8.GetBytes(sql + "\0");
        IntPtr statement;
        int result;
        fixed (byte* text = bytes)
        {
            result = Sqlite3PrepareV2(_db, text, -1, &statement, null);
        }

        if (result != Ok)
        {
            throw new SqliteException(result, $"{MessageOf(_db)}（{FirstLine(sql)}）");
        }

        return new SqliteStatement(this, statement);
    }

    public void Execute(string sql)
    {
        var bytes = Encoding.UTF8.GetBytes(sql + "\0");
        byte* error = null;
        int result;
        fixed (byte* text = bytes)
        {
            result = Sqlite3Exec(_db, text, IntPtr.Zero, IntPtr.Zero, &error);
        }

        if (result != Ok)
        {
            var message = error is null ? MessageOf(_db) : Utf8(error);
            if (error is not null)
            {
                Sqlite3Free(error);
            }

            throw new SqliteException(result, message);
        }
    }

    public string ErrorMessage => MessageOf(_db);

    public void Dispose()
    {
        if (_db == IntPtr.Zero)
        {
            return;
        }

        Sqlite3CloseV2(_db);
        _db = IntPtr.Zero;
    }

    internal IntPtr Handle => _db;

    internal static bool IsRow(int result) => result == Row;

    internal static bool IsDone(int result) => result == Done;

    internal static string Utf8(byte* text)
    {
        if (text is null)
        {
            return string.Empty;
        }

        return Marshal.PtrToStringUTF8((IntPtr)text) ?? string.Empty;
    }

    private static string MessageOf(IntPtr db)
        => db == IntPtr.Zero ? "数据库没有打开" : Utf8(Sqlite3Errmsg(db));

    private static string FirstLine(string sql)
    {
        var newline = sql.IndexOfAny(new[] { '\r', '\n' });
        var line = (newline < 0 ? sql : sql[..newline]).Trim();
        return line.Length <= 60 ? line : line[..60] + "…";
    }

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2")]
    private static partial int Sqlite3OpenV2(byte* fileName, IntPtr* db, int flags, byte* vfs);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")]
    private static partial int Sqlite3CloseV2(IntPtr db);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_errmsg")]
    private static partial byte* Sqlite3Errmsg(IntPtr db);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_exec")]
    private static partial int Sqlite3Exec(IntPtr db, byte* sql, IntPtr callback, IntPtr argument, byte** error);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_free")]
    private static partial void Sqlite3Free(byte* memory);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2")]
    private static partial int Sqlite3PrepareV2(IntPtr db, byte* sql, int bytes, IntPtr* statement, byte** tail);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_last_insert_rowid")]
    private static partial long Sqlite3LastInsertRowId(IntPtr db);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_changes")]
    private static partial int Sqlite3Changes(IntPtr db);
}

internal sealed unsafe partial class SqliteStatement : IDisposable
{
    private readonly SqliteConnection _connection;
    private IntPtr _statement;
    private bool _finished;

    internal SqliteStatement(SqliteConnection connection, IntPtr statement)
    {
        _connection = connection;
        _statement = statement;
        _finished = false;
    }

    public SqliteStatement BindText(int index, string? value)
    {
        if (value is null)
        {
            return BindNull(index);
        }

        var bytes = Encoding.UTF8.GetBytes(value);
        fixed (byte* text = bytes)
        {
            Check(Sqlite3BindText(_statement, index, text, bytes.Length, Transient));
        }

        return this;
    }

    public SqliteStatement BindInt64(int index, long value)
    {
        Check(Sqlite3BindInt64(_statement, index, value));
        return this;
    }

    public SqliteStatement BindBlob(int index, ReadOnlySpan<byte> value)
    {
        fixed (byte* data = value)
        {
            Check(Sqlite3BindBlob(_statement, index, data, value.Length, Transient));
        }

        return this;
    }

    public SqliteStatement BindNull(int index)
    {
        Check(Sqlite3BindNull(_statement, index));
        return this;
    }

    /// <summary>走一行返回 true；走到末尾返回 false。到末尾后再调用会自动 reset。</summary>
    public bool Step()
    {
        if (_finished)
        {
            Sqlite3Reset(_statement);
            _finished = false;
        }

        var result = Sqlite3Step(_statement);
        if (SqliteConnection.IsRow(result))
        {
            return true;
        }

        if (SqliteConnection.IsDone(result))
        {
            _finished = true;
            return false;
        }

        throw new SqliteException(result, _connection.ErrorMessage);
    }

    public void Reset()
    {
        Sqlite3Reset(_statement);
        _finished = false;
    }

    public bool IsNull(int index) => Sqlite3ColumnType(_statement, index) == 5; // SQLITE_NULL

    public string? GetText(int index)
    {
        if (IsNull(index))
        {
            return null;
        }

        var text = Sqlite3ColumnText(_statement, index);
        return text is null ? null : SqliteConnection.Utf8(text);
    }

    public long GetInt64(int index) => Sqlite3ColumnInt64(_statement, index);

    public int GetInt32(int index) => (int)Sqlite3ColumnInt64(_statement, index);

    public byte[]? GetBlob(int index)
    {
        if (IsNull(index))
        {
            return null;
        }

        var data = Sqlite3ColumnBlob(_statement, index);
        var length = Sqlite3ColumnBytes(_statement, index);
        if (data is null || length <= 0)
        {
            return Array.Empty<byte>();
        }

        var bytes = new byte[length];
        new ReadOnlySpan<byte>(data, length).CopyTo(bytes);
        return bytes;
    }

    public void Dispose()
    {
        if (_statement == IntPtr.Zero)
        {
            return;
        }

        Sqlite3Finalize(_statement);
        _statement = IntPtr.Zero;
    }

    private static void Check(int result)
    {
        if (result != 0)
        {
            throw new SqliteException(result, $"绑定参数失败（{result}）");
        }
    }

    private static readonly IntPtr Transient = new(-1); // SQLITE_TRANSIENT

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_text")]
    private static partial int Sqlite3BindText(IntPtr statement, int index, byte* value, int bytes, IntPtr destructor);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_int64")]
    private static partial int Sqlite3BindInt64(IntPtr statement, int index, long value);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_blob")]
    private static partial int Sqlite3BindBlob(IntPtr statement, int index, byte* value, int bytes, IntPtr destructor);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_null")]
    private static partial int Sqlite3BindNull(IntPtr statement, int index);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_step")]
    private static partial int Sqlite3Step(IntPtr statement);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_reset")]
    private static partial int Sqlite3Reset(IntPtr statement);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")]
    private static partial int Sqlite3Finalize(IntPtr statement);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_column_type")]
    private static partial int Sqlite3ColumnType(IntPtr statement, int index);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text")]
    private static partial byte* Sqlite3ColumnText(IntPtr statement, int index);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_column_int64")]
    private static partial long Sqlite3ColumnInt64(IntPtr statement, int index);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_column_blob")]
    private static partial byte* Sqlite3ColumnBlob(IntPtr statement, int index);

    [LibraryImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes")]
    private static partial int Sqlite3ColumnBytes(IntPtr statement, int index);
}

internal sealed class SqliteException : Exception
{
    public SqliteException(int result, string message)
        : base(message)
    {
        Result = result;
    }

    public int Result { get; }
}

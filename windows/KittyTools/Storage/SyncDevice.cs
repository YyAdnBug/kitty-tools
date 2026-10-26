// 本机编号（PLAN-v5 §2.1）：大写 UUID，存在 kitty.sqlite3 的 sync_device 表里，同时记 MachineGuid。
// 数据目录被拷到另一台电脑（MachineGuid 对不上）就换新编号，免得两台电脑用同一个编号改同一份钟。
using System.Security.Cryptography;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;
using Microsoft.Win32;

namespace KittyTools;

internal sealed class SyncDevice
{
    private readonly Database _database;

    private SyncDevice(Database database)
    {
        _database = database;
    }

    public static SyncDevice? Instance { get; private set; }

    public string Id { get; private set; } = string.Empty;

    public string? Library { get; private set; }

    public static SyncDevice Start(Database database)
    {
        var device = new SyncDevice(database);
        device.LoadOrCreate();
        Instance = device;
        return device;
    }

    public static string MachineGuid()
    {
        try
        {
            return Registry.GetValue(
                @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography",
                "MachineGuid",
                null) as string ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    public void SetLibrary(string? library)
    {
        Library = library;
        using var statement = _database.Connection.Prepare(
            "UPDATE sync_device SET library = $library WHERE id = $id;");
        statement.BindText(1, library);
        statement.BindText(2, Id);
        statement.Step();
    }

    /// <summary>库被退回去了（文件夹里的 epoch 比本机大）：换一个新编号。</summary>
    public void Rotate()
    {
        using (var statement = _database.Connection.Prepare("DELETE FROM sync_device;"))
        {
            statement.Step();
        }

        LoadOrCreate();
        Log.Info("sync.device-rotated");
    }

    private void LoadOrCreate()
    {
        var guid = MachineGuid();
        using (var statement = _database.Connection.Prepare(
                   "SELECT id, machine_guid, library FROM sync_device LIMIT 1;"))
        {
            if (statement.Step())
            {
                var id = statement.GetText(0) ?? string.Empty;
                var storedGuid = statement.GetText(1) ?? string.Empty;
                var library = statement.GetText(2);
                if (SyncFolderRules.IsDeviceName(id) &&
                    (string.IsNullOrEmpty(guid) || string.IsNullOrEmpty(storedGuid) || storedGuid == guid))
                {
                    Id = id;
                    Library = string.IsNullOrEmpty(library) ? null : library;
                    return;
                }
            }
        }

        Id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        Library = null;
        using (var insert = _database.Connection.Prepare(
                   "INSERT OR REPLACE INTO sync_device(id, machine_guid, library) VALUES ($id, $guid, '');"))
        {
            insert.BindText(1, Id);
            insert.BindText(2, guid);
            insert.Step();
        }

        Log.Info("sync.device-created");
    }
}

/// <summary>同步账本：clips / vocabulary 放库里，engines / services 放数据目录的 sync-ledger.json（PLAN-v5 §4.1）。</summary>
internal sealed class SyncLedger
{
    private readonly Database _database;

    private SyncLedger(Database database)
    {
        _database = database;
    }

    public static SyncLedger? Instance { get; private set; }

    /// <summary>落地和账本同一个事务要用（R13）。</summary>
    public Database Database => _database;

    public static SyncLedger Start(Database database)
    {
        Instance = new SyncLedger(database);
        return Instance;
    }

    public string? Read(string kind)
    {
        if (kind is "clips" or "vocabulary")
        {
            using var statement = _database.Connection.Prepare(
                "SELECT ledger FROM sync_ledger WHERE kind = $kind;");
            statement.BindText(1, kind);
            return statement.Step() ? statement.GetText(0) : null;
        }

        return ReadFile().GetValueOrDefault(kind);
    }

    public string? ReadLibrary(string kind)
    {
        if (kind is "clips" or "vocabulary")
        {
            using var statement = _database.Connection.Prepare(
                "SELECT library FROM sync_ledger WHERE kind = $kind;");
            statement.BindText(1, kind);
            return statement.Step() ? statement.GetText(0) : null;
        }

        // 存在 sync-ledger.json 的两类：库编号记在旁边的「<类别>@library」（R26 之前没记，读出来是 null，照旧用）。
        return ReadFile().GetValueOrDefault(kind + "@library");
    }

    public void Write(string kind, string library, string ledger)
    {
        if (kind is "clips" or "vocabulary")
        {
            using var statement = _database.Connection.Prepare(
                """
                INSERT INTO sync_ledger(kind, library, ledger) VALUES ($kind, $library, $ledger)
                ON CONFLICT(kind) DO UPDATE SET library = $library, ledger = $ledger;
                """);
            statement.BindText(1, kind);
            statement.BindText(2, library);
            statement.BindText(3, ledger);
            statement.Step();
            return;
        }

        var map = ReadFile();
        map[kind] = ledger;
        map[kind + "@library"] = library;
        WriteFile(map);
    }

    /// <summary>本机这一格的版本钟次数：存在 ~clock 这一行，不进同步文件。</summary>
    public int NextCounter()
    {
        var text = Read("~clock");
        var counter = int.TryParse(text, out var value) ? value : 0;
        counter++;
        WriteRawClock(counter);
        return counter;
    }

    /// <summary>本机上一次写出去的 device.json 的 epoch（用来认出库被退回去了）。</summary>
    public int ReadEpoch()
    {
        using var statement = _database.Connection.Prepare(
            "SELECT ledger FROM sync_ledger WHERE kind = '~epoch';");
        return statement.Step() && int.TryParse(statement.GetText(0), out var value) ? value : 0;
    }

    public void WriteEpoch(int epoch) => WriteRaw("~epoch", epoch.ToString(
        System.Globalization.CultureInfo.InvariantCulture));

    private void WriteRawClock(int counter)
        => WriteRaw("~clock", counter.ToString(System.Globalization.CultureInfo.InvariantCulture));

    private void WriteRaw(string kind, string value)
    {
        using var statement = _database.Connection.Prepare(
            """
            INSERT INTO sync_ledger(kind, library, ledger) VALUES ($kind, '', $value)
            ON CONFLICT(kind) DO UPDATE SET ledger = $value;
            """);
        statement.BindText(1, kind);
        statement.BindText(2, value);
        statement.Step();
    }

    private Dictionary<string, string> ReadFile()
    {
        var path = Path.Combine(Paths.DataDirectory, "sync-ledger.json");
        try
        {
            if (!File.Exists(path))
            {
                return new Dictionary<string, string>();
            }

            using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                ? document.RootElement.EnumerateObject()
                    .Where(property => property.Value.ValueKind == System.Text.Json.JsonValueKind.String)
                    .ToDictionary(property => property.Name, property => property.Value.GetString() ?? string.Empty)
                : new Dictionary<string, string>();
        }
        catch
        {
            return new Dictionary<string, string>();
        }
    }

    private void WriteFile(Dictionary<string, string> map)
    {
        var path = Path.Combine(Paths.DataDirectory, "sync-ledger.json");
        var temporary = path + ".tmp";
        Directory.CreateDirectory(Paths.DataDirectory);
        var builder = new System.Text.StringBuilder("{");
        var first = true;
        foreach (var (key, value) in map.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            Core.Sync.CanonicalJson.WriteString(key, builder);
            builder.Append(':');
            Core.Sync.CanonicalJson.WriteString(value, builder);
        }

        builder.Append('}');
        File.WriteAllText(temporary, builder.ToString());
        File.Move(temporary, path, overwrite: true);
    }
}

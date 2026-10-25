// 每日备份（第三版 §2.1，规则在 Core/BackupPlan）：另开一个只读连接，在后台线程上跑。
// 顺序照 mac 的 Storage/Backup.swift：
//   1. PRAGMA quick_check 是 ok；
//   2. VACUUM INTO 写出半成品；
//   3. 在半成品上删掉不留的行（普通历史 / 没收藏的翻译 / 启动器使用记录）；
//   4. 再 VACUUM 一遍（只删行的话，内容还留在文件的空闲页里）；
//   5. 再检查一遍是不是好的；
//   6. 改成正式名字 backups\kitty-YYYY-MM-DD.sqlite3；
//   7. 最后才删超出 3 份的旧备份。
// 任何一步失败：已有的备份一个字节都不动，半成品（连 -wal / -shm）删掉。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class Backup
{
    public enum Outcome
    {
        Made,
        NotDue,
        Damaged,
        Failed,
    }

    private static int _running;

    /// <summary>今天还没备过就备一份；调用方放到后台线程（不碰主连接）。</summary>
    public static Outcome Run(string dataDirectory, DateTime now)
    {
        // 同一时间只跑一份（启动、锁屏、唤醒可能撞在一起）。
        if (Interlocked.Exchange(ref _running, 1) == 1)
        {
            return Outcome.NotDue;
        }

        try
        {
            return RunCore(dataDirectory, now);
        }
        finally
        {
            Interlocked.Exchange(ref _running, 0);
        }
    }

    private static Outcome RunCore(string dataDirectory, DateTime now)
    {
        var folder = Path.Combine(dataDirectory, BackupPlan.FolderName);
        if (!BackupPlan.IsDue(folder, now))
        {
            return Outcome.NotDue;
        }

        var database = Path.Combine(dataDirectory, BackupPlan.DatabaseName);
        if (!File.Exists(database) || !IsIntact(database))
        {
            Log.Warn("backup.damaged");
            return Outcome.Damaged;
        }

        var target = Path.Combine(folder, BackupPlan.Name(now));
        var partial = Path.Combine(folder, "kitty.partial");
        Discard(partial);
        try
        {
            Directory.CreateDirectory(folder);
            // 用普通的读写连接做 VACUUM INTO：winsqlite3 上只读连接会报 attempt to write a readonly database。
            // 它只读源库、写目标文件；和 UI 那个连接同时开没事（WAL + busy_timeout）。
            using (var source = new SqliteConnection(database))
            {
                source.Execute($"VACUUM INTO {Quote(partial)};");
            }

            using (var copy = new SqliteConnection(partial))
            {
                foreach (var statement in BackupPlan.DroppedStatements(HasTable(copy, "translations")))
                {
                    copy.Execute(statement);
                }

                copy.Execute("VACUUM;");
            }

            if (!IsIntact(partial))
            {
                throw new InvalidOperationException("备份出来的文件不完整");
            }

            File.Move(partial, target, overwrite: true);
            // 在 partial 上开过连接：它的 -wal / -shm 和 -journal 别留在 backups\ 里。
            Discard(partial);
            Rotate(folder, target, now);
            Log.Info($"backup.made {Path.GetFileName(target)}");
            return Outcome.Made;
        }
        catch (Exception ex)
        {
            Log.Error($"backup.failed {ex.GetType().Name} {ex.Message}");
            Discard(partial);
            return Outcome.Failed;
        }
    }

    /// <summary>最近的、读得出来的那份备份；最新的坏了就往前找。</summary>
    public static (string Path, DateTime Day)? LatestUsable(string dataDirectory)
    {
        foreach (var copy in List(dataDirectory))
        {
            if (IsIntact(copy.Path))
            {
                return copy;
            }
        }

        return null;
    }

    /// <summary>已有的备份，新的在前（只认文件名里的日期）。</summary>
    public static List<(string Path, DateTime Day)> List(string dataDirectory)
    {
        var folder = Path.Combine(dataDirectory, BackupPlan.FolderName);
        if (!Directory.Exists(folder))
        {
            return new List<(string, DateTime)>();
        }

        var copies = new List<(string Path, DateTime Day)>();
        foreach (var file in Directory.EnumerateFiles(folder, "kitty-*.sqlite3"))
        {
            if (BackupPlan.DayOf(Path.GetFileName(file)) is { } day)
            {
                copies.Add((file, day));
            }
        }

        return copies.OrderByDescending(copy => copy.Day).ToList();
    }

    public static bool IsIntact(string path)
    {
        try
        {
            using var connection = new SqliteConnection(path, readOnly: true);
            using var statement = connection.Prepare("PRAGMA quick_check;");
            var ok = true;
            while (statement.Step())
            {
                if (!string.Equals(statement.GetText(0), "ok", StringComparison.OrdinalIgnoreCase))
                {
                    ok = false;
                }
            }

            return ok;
        }
        catch (Exception ex)
        {
            Log.Warn($"backup.check-failed {ex.GetType().Name}");
            return false;
        }
    }

    private static void Rotate(string folder, string written, DateTime now)
    {
        var copies = List(Path.GetDirectoryName(folder)!)
            .Select(copy => (copy.Path, copy.Day))
            .ToList();
        foreach (var old in BackupPlan.Expired(copies, written, now))
        {
            try
            {
                File.Delete(old);
            }
            catch (Exception ex)
            {
                Log.Warn($"backup.rotate-failed {ex.GetType().Name}");
            }
        }
    }

    private static bool HasTable(SqliteConnection connection, string name)
    {
        try
        {
            using var statement = connection.Prepare(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = $name;");
            statement.BindText(1, name);
            return statement.Step();
        }
        catch
        {
            return false;
        }
    }

    private static string Quote(string path) => "'" + path.Replace("'", "''") + "'";

    private static void Discard(string partial)
    {
        foreach (var suffix in new[] { "", "-journal", "-wal", "-shm" })
        {
            try
            {
                if (File.Exists(partial + suffix))
                {
                    File.Delete(partial + suffix);
                }
            }
            catch
            {
                // 删不掉就留着，下次开头再清。
            }
        }
    }
}

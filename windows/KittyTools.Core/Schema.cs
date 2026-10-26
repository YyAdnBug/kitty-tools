// 数据库结构的逐版本迁移（纯数据 + 纯函数，配单测）。
// 第二版 §2 第 14 条：以前 user_version < 2 时只 CREATE TABLE IF NOT EXISTS，以后改表结构就是坏的。
// 现在每一步对应一个版本号、各步幂等（IF NOT EXISTS），从当前版本依次往上跑。
namespace KittyTools.Core;

public readonly record struct SchemaStep(int Version, string Description, string Sql);

/// <summary>迁移的执行者：真库是 SqliteConnection，单测里是假的。</summary>
public interface ISchemaExecutor
{
    /// <summary>当前版本（PRAGMA user_version）。</summary>
    int Version { get; }

    void Execute(string sql);

    void SetVersion(int version);
}

public static class Schema
{
    /// <summary>代码里写的最新版本。加表 / 加列就往下加一步。</summary>
    /// <summary>代码认识的最新版本（跟着步骤表走，别再手改）。</summary>
    public static int CurrentVersion => Steps.Count == 0 ? 0 : Steps[^1].Version;

    /// <summary>所有步骤，按版本升序；每步都在自己的事务里跑。</summary>
    public static readonly IReadOnlyList<SchemaStep> Steps = new[]
    {
        new SchemaStep(
            1,
            "clips：剪贴板历史",
            """
            CREATE TABLE IF NOT EXISTS clips(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              text TEXT,
              file_paths TEXT,
              html TEXT,
              rtf TEXT,
              image_hash TEXT,
              width INTEGER NOT NULL DEFAULT 0,
              height INTEGER NOT NULL DEFAULT 0,
              image_bytes INTEGER NOT NULL DEFAULT 0,
              source_exe TEXT,
              source_name TEXT,
              copied_at INTEGER NOT NULL,
              favorite INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS clips_copied_at ON clips(copied_at DESC, id DESC);
            """),
        new SchemaStep(
            2,
            "launcher_usage：启动器使用记录",
            """
            CREATE TABLE IF NOT EXISTS launcher_usage(
              query TEXT NOT NULL,
              kind TEXT NOT NULL,
              target TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '',
              score INTEGER NOT NULL,
              used_at INTEGER NOT NULL,
              PRIMARY KEY(query, kind, target)
            );
            """),
        new SchemaStep(
            3,
            "translations：翻译历史与生词本（第三版第 2 批）",
            """
            CREATE TABLE IF NOT EXISTS translations(
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              source_lang TEXT,
              target_lang TEXT NOT NULL,
              result TEXT NOT NULL,
              service TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              favorite INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS translations_created_at ON translations(created_at DESC);
            CREATE UNIQUE INDEX IF NOT EXISTS translations_favorite_unique
              ON translations(source, target_lang) WHERE favorite = 1;
            """),
        new SchemaStep(
            4,
            "clips 的片段 / 备注 / 收藏夹，新表 clip_groups（第三版第 3 批）",
            """
            ALTER TABLE clips ADD COLUMN uid TEXT;
            ALTER TABLE clips ADD COLUMN snippet INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE clips ADD COLUMN note TEXT;
            ALTER TABLE clips ADD COLUMN group_id TEXT;
            CREATE UNIQUE INDEX IF NOT EXISTS clips_uid ON clips(uid) WHERE uid IS NOT NULL;
            CREATE TABLE IF NOT EXISTS clip_groups(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE,
              position INTEGER NOT NULL,
              created_at INTEGER NOT NULL
            );
            """),
        new SchemaStep(
            5,
            "clips 的识字结果 ocr_text（第三版第 4 批）",
            """
            ALTER TABLE clips ADD COLUMN ocr_text TEXT;
            """),
        new SchemaStep(
            6,
            "launcher_favorites：启动器收藏与顺序（第三版第 5 批）",
            """
            CREATE TABLE IF NOT EXISTS launcher_favorites(
              target TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '',
              position INTEGER NOT NULL,
              added_at INTEGER NOT NULL
            );
            """),
        new SchemaStep(
            7,
            "sync_ledger / sync_device：同步账本与本机编号（第五版）",
            """
            CREATE TABLE IF NOT EXISTS sync_ledger(
              kind TEXT PRIMARY KEY,
              library TEXT NOT NULL,
              ledger TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_device(
              id TEXT PRIMARY KEY,
              machine_guid TEXT NOT NULL DEFAULT '',
              library TEXT NOT NULL DEFAULT ''
            );
            """),
        new SchemaStep(
            8,
            "shots：截图历史（PLAN-v8 第 1 批）",
            """
            CREATE TABLE IF NOT EXISTS shots(
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              pixel_width INTEGER NOT NULL DEFAULT 0,
              pixel_height INTEGER NOT NULL DEFAULT 0,
              scale_percent INTEGER NOT NULL DEFAULT 100,
              source_name TEXT,
              saved_path TEXT,
              file_path TEXT,
              annotations TEXT,
              pinned_at INTEGER,
              bytes INTEGER NOT NULL DEFAULT 0,
              frame TEXT
            );
            CREATE INDEX IF NOT EXISTS shots_created_at ON shots(created_at DESC);
            """),
    };

    /// <summary>从 currentVersion 开始还要跑的步骤（升序）。比代码新的库（用户装过更新的版本）一步都不跑。</summary>
    public static IReadOnlyList<SchemaStep> Pending(int currentVersion)
        => Steps.Where(step => step.Version > currentVersion).OrderBy(step => step.Version).ToList();

    /// <summary>
    /// 依次执行待跑的步骤，每一步跑完把 user_version 记成那个版本。
    /// 这样中途失败时，下次启动会从失败那一步重来（各步幂等，重来没事）。
    /// </summary>
    public static int Migrate(ISchemaExecutor executor)
    {
        var ran = 0;
        foreach (var step in Pending(executor.Version))
        {
            executor.Execute("BEGIN IMMEDIATE;");
            try
            {
                executor.Execute(step.Sql);
                executor.SetVersion(step.Version);
                executor.Execute("COMMIT;");
            }
            catch
            {
                executor.Execute("ROLLBACK;");
                throw;
            }

            ran++;
        }

        return ran;
    }
}

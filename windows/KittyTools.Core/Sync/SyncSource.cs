// 同步的两个接口（REVIEW R26；照 windows/reference/mac-sync/SyncLedger.swift 的 SyncSource）：
// - ISyncSource：一类数据怎么接进同步。片段与收藏、生词本、网页搜索、翻译服务各自的仓库（App 里的薄适配）实现它，
//   编出去 / 落回来的规则在 Core 的 ClipSync / VocabularySync / EngineSync / ServiceSync。
// - ISyncDevice：本机编号、文件夹的库编号、上一次写出去的 device.json 是第几轮（认出库被退回去了要用）。
// **账本和数据同一个事务**（SyncEngine 文件头「执行层必须守住的」）：Apply 落改动和存账本一起成、一起不成；
// 落改动没成就不存账本。
namespace KittyTools.Core.Sync;

public interface ISyncSource
{
    /// <summary>clips / vocabulary / engines / services。</summary>
    string Kind { get; }

    /// <summary>第一次合时认「同一条」的键（同样的内容只留文件夹里那条）；null = 不去重。</summary>
    string? JoinKey(string value);

    /// <summary>本机该同步的那份：编号 → 内容（键排好序；编 → 落 → 再编字节一样）。null = 这一类这一轮先不合
    /// （仓库没起来、面板里有还能撤销的删除）：当成空表交进去的话，账本里的每一条都成了「本机删了」，删到每一台。</summary>
    IReadOnlyDictionary<string, string>? Values();

    /// <summary>账本：没有、是别的库的 = null（第一次合）；读不出来抛错（这一类先不合：当成第一次合的话，本机上一轮
    /// 之后改的会被盖回去、删的被救回来）。</summary>
    SyncLedgerData? Ledger(string library);

    /// <summary>落合并出来的改动（编号 → 新内容，null = 不再留着），在同一个事务里存账本。
    /// 成了返回 null；没成返回原因（什么都没改，账本也没存）。</summary>
    string? Apply(IReadOnlyDictionary<string, string?> changes, SyncLedgerData ledger, string library);
}

public interface ISyncDevice
{
    /// <summary>本机编号（大写 UUID）。</summary>
    string Id { get; }

    /// <summary>上一次同步的那个文件夹的库编号。</summary>
    string? Library { get; }

    void SetLibrary(string library);

    /// <summary>库被退回去了：换一个新编号（旧编号那个子文件夹在别人眼里就是一台不再改动的电脑）。</summary>
    void Rotate();

    /// <summary>本机上一次写出去的 device.json 的 epoch（存在和数据同一个库里，从备份恢复时一起退回去）。</summary>
    int Epoch { get; }

    void SetEpoch(int epoch);
}

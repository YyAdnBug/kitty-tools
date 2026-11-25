// 同步停了要让人知道（照 mac 0.10.1 NoteSyncer 第五轮体检 U1，f722e397）：
// - 要你去处理的（不是那个文件夹、更新版本写的、服务器不认密码 / 不让读写、凭据管理器里没密码）马上说一次，带「打开同步设置」；
// - 别的（文件夹不在、还没下载完、连不上……多半自己会好）一直停着满 QuietSpan（30 分钟）才说（睡着的那段不算：调用方按
//   不含睡眠的时钟给 now）；
// - 一段停着里同一种只说一次（别的那几种合起来算一种），说过的同时主界面底栏「设置」挂一个小橙点（NeedsAttention）；
// - 好好走完一轮、停在等确认、关掉同步，这一段就算完了（点收掉，下回再停从头算）。刹车照旧自己提示，不走这里。
// 纯状态机，单测 SyncAttentionTests；轻提示和橙点在 App 的 Syncer。
namespace KittyTools.Core.Sync;

public sealed class SyncAttention
{
    public static readonly TimeSpan QuietSpan = TimeSpan.FromMinutes(30);

    /// <summary>服务器不认这组用户名密码（401）。</summary>
    public const string Unauthorized = "unauthorized";

    /// <summary>服务器不让读写这个文件夹（403）。</summary>
    public const string Forbidden = "forbidden";

    /// <summary>凭据管理器里没有服务器的密码。</summary>
    public const string NoPassword = "no-password";

    /// <summary>不是那个文件夹（标记被换掉 / 里面有别的东西）。</summary>
    public const string NotTheFolder = "not-the-folder";

    /// <summary>更新版本写的（格式或某一类读不懂）。</summary>
    public const string Newer = "newer";

    private readonly HashSet<string> _told = new(StringComparer.Ordinal);
    private TimeSpan? _since;

    /// <summary>说过了、还没好：主界面底栏「设置」挂小橙点。</summary>
    public bool NeedsAttention { get; private set; }

    /// <summary>要你处理的那几种。</summary>
    public static bool NeedsYou(string? problem)
        => problem is Unauthorized or Forbidden or NoPassword or NotTheFolder or Newer;

    /// <summary>SyncRunner 停下时的那句话属于哪一种要你处理的（别的给 null）。</summary>
    public static string? Classify(string message) => message switch
    {
        SyncRunner.NewerFormat or ClipSync.Unreadable => Newer,
        SyncRunner.ForeignFolder => NotTheFolder,
        _ => null,
    };

    /// <summary>
    /// 这一轮停下了（problem：要你处理的那一种，别的给 null；now：不含睡眠的时钟）。返回 true = 现在该说一次。
    /// </summary>
    public bool Stopped(string? problem, TimeSpan now)
    {
        var since = _since ??= now;
        var urgent = NeedsYou(problem);
        if (!urgent && now - since < QuietSpan)
        {
            return false;
        }

        NeedsAttention = true;
        return _told.Add(urgent ? problem! : string.Empty);
    }

    /// <summary>这一段停着结束了（好好走完一轮、停在等确认、关掉了同步）：小橙点收掉，下回再停从头算。</summary>
    public void Recovered()
    {
        _since = null;
        _told.Clear();
        NeedsAttention = false;
    }

    /// <summary>轻提示上那一句（短；为什么、怎么办设置页那一行写全了）。</summary>
    public static string Notice(string? problem, string message) => problem switch
    {
        Unauthorized => "服务器不认这个密码，先不再自动重试",
        Forbidden => "服务器不让读写这个文件夹，先不再自动重试",
        NoPassword => "凭据管理器里没有服务器的密码",
        NotTheFolder => "同步文件夹里的同步记录被换掉或删了",
        Newer => "有更新版本的 Kitty Tools 写的东西，先更新这台电脑上的",
        _ => message,
    };
}

// 启动器的「ip」（纯函数，配单测；照 mac 2026-10-28 的 Launcher/IPAddresses.swift）：输入 ip（或「ip 地址」「内网 ip」这类）
// 排在最前面列本机地址和外网地址，Enter 粘贴、Ctrl+Enter 只复制（同计算结果）。
// 本机：每块联网的网卡一个 IPv4 一行（回环、169.254 自分配的、代理 TUN 的 198.18 假地址不列），默认路由走的那块排第一；
// VPN 的写「内网」，其余写「局域网」，网卡名用 设置 › 网络和 Internet 里的叫法（WLAN、以太网）。
// 外网：本机不知道，问两家——国内的 myip.ipip.net、国外的 api.ipify.org：开着代理时国内网站直连、国外网站走代理，
// 两家看到的常常不一样；一样就一行「外网」，不一样各一行写清是访问哪边时的。读网卡、联网查在 App 的 IpAddresses。
using System.Text.RegularExpressions;

namespace KittyTools.Core;

/// <summary>一块网卡上的一个 IPv4：网卡编号（行的身份用）、给人看的名字、地址、是不是 VPN。</summary>
public readonly record struct LocalAddress(string Interface, string Name, string Address, bool Vpn);

/// <summary>外网地址问谁：国内的（直连）和国外的（开着代理时是代理的出口）。</summary>
public enum IpService
{
    Domestic,
    Overseas,
}

public enum IpLookupState
{
    Pending,
    Found,
    Failed,
}

/// <summary>一家查询服务的结果。</summary>
public readonly record struct IpLookup(IpLookupState State, string? Address = null);

public static partial class LauncherIp
{
    /// <summary>输到 ip 之后等多久才联网查（打「iphone」路过 ip 时不发请求）。</summary>
    public const int LookupDelayMs = 300;

    /// <summary>问一家最多等多久。</summary>
    public const int LookupTimeoutMs = 5000;

    private static readonly HashSet<string> Keywords = new(StringComparer.Ordinal)
    {
        "ip", "ip地址", "本机ip", "局域网ip", "内网ip", "外网ip",
    };

    public static Uri Url(IpService service) => service switch
    {
        IpService.Domestic => new Uri("https://myip.ipip.net/s"),
        _ => new Uri("https://api.ipify.org"),
    };

    /// <summary>「ip」「IP 地址」「内网ip」…（不分大小写和空格）。</summary>
    public static bool Matches(string query)
        => Keywords.Contains(new string(LauncherMatch.Fold(query).Where(character => !char.IsWhiteSpace(character)).ToArray()));

    /// <summary>
    /// 能给别人用的地址：169.254 是没拿到地址时自分配的，198.18 / 198.19 是代理软件 TUN 模式的假地址，都不列。
    /// </summary>
    public static bool IsUsable(string address)
    {
        var parts = address.Split('.');
        if (parts.Length != 4 || !parts.All(part => byte.TryParse(part, out _)))
        {
            return false;
        }

        var first = byte.Parse(parts[0]);
        var second = byte.Parse(parts[1]);
        return first != 127 && !(first == 169 && second == 254) && !(first == 198 && (second & 0xFE) == 18);
    }

    /// <summary>本机那几行：默认路由走的网卡排第一，其余按原顺序；一个都没有时一行「没有连上网络」（不能粘贴）。</summary>
    public static List<LauncherItem> LocalItems(IReadOnlyList<LocalAddress> addresses, string? primary)
    {
        if (addresses.Count == 0)
        {
            return new List<LauncherItem>
            {
                new() { Kind = LauncherKind.Ip, Target = "lan", Title = "局域网 IP", Subtitle = "没有连上网络" },
            };
        }

        return addresses.Where(local => local.Interface == primary)
            .Concat(addresses.Where(local => local.Interface != primary))
            .Select(local => new LauncherItem
            {
                Kind = LauncherKind.Ip,
                // 目标以 vpn: / lan: 开头：行首的图标按它取（VPN 是锁、局域网是网络）。
                Target = (local.Vpn ? "vpn:" : "lan:") + local.Interface + " " + local.Address,
                Title = local.Address,
                Subtitle = (local.Vpn ? "内网" : "局域网") + " · " + (local.Name.Length > 0 ? local.Name : local.Vpn ? "VPN" : local.Interface),
                Payload = local.Address,
            })
            .ToList();
    }

    /// <summary>
    /// 两家的结果拼成的行：查到的地址一样（或只查到一家）一行「外网」，不一样各一行（国内的在前）；都没查到时一行占位（不能粘贴）。
    /// 第一行的目标一直是 public：查到了原地换，选中不跳。
    /// </summary>
    public static List<LauncherItem> PublicItems(IReadOnlyDictionary<IpService, IpLookup> lookups)
    {
        var found = new[] { IpService.Domestic, IpService.Overseas }
            .Where(service => lookups.TryGetValue(service, out var lookup) && lookup.State == IpLookupState.Found && lookup.Address is not null)
            .Select(service => (Service: service, Address: lookups[service].Address!))
            .ToList();
        if (found.Select(entry => entry.Address).Distinct().Count() > 1)
        {
            return found.Select(entry => new LauncherItem
            {
                Kind = LauncherKind.Ip,
                Target = entry.Service == IpService.Domestic ? "public" : "public-overseas",
                Title = entry.Address,
                Subtitle = entry.Service == IpService.Domestic ? "外网 · 访问国内网站时" : "外网 · 访问国外网站时",
                Payload = entry.Address,
            }).ToList();
        }

        if (found.Count > 0)
        {
            return new List<LauncherItem>
            {
                new() { Kind = LauncherKind.Ip, Target = "public", Title = found[0].Address, Subtitle = "外网", Payload = found[0].Address },
            };
        }

        var pending = lookups.Values.Any(lookup => lookup.State == IpLookupState.Pending);
        return new List<LauncherItem>
        {
            new()
            {
                Kind = LauncherKind.Ip,
                Target = "public",
                Title = "外网 IP",
                Subtitle = pending ? "正在查询…" : "没查到：没有联网，或查询超时",
            },
        };
    }

    /// <summary>查询服务回的一行纯文本里的 IPv4；被劫持到登录页这类回的不是一个地址，算没查到。</summary>
    public static string? AddressIn(string text)
    {
        var trimmed = text.Trim();
        var match = AddressRegex().Match(trimmed);
        return match.Success && Enumerable.Range(1, 4).All(group => byte.TryParse(match.Groups[group].Value, out _))
            ? trimmed
            : null;
    }

    [GeneratedRegex(@"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")]
    private static partial Regex AddressRegex();
}

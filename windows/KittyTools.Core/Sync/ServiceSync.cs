// 翻译服务列表接进同步（REVIEW R26；照 windows/reference/mac-sync/TranslateServiceSync.swift）：一个服务一个记录（编号 =
// 服务编号：内置的每台都是同一个，自建的 AI 服务是 "ai:<8 位>"），内容是它的配置；顺序单独一条（~order）。**密钥不同步**。
// 第一次合时同协议、同地址、同模型的自建 AI 服务只留文件夹里那个，本机那个的密钥搬给它（它在本机还没有密钥时）。
// 别处删了的服务只拿出列表、不删凭据管理器里的密钥。
// 编码：键按字母排；可空的字段是 null 才不写（空串照写）——两边编 → 落 → 再编都一字不差，写成空串的那台不会被当成
// 「这一版读不懂」。usesDeepLX 只在 true 时写（Windows 这边是布尔）。
namespace KittyTools.Core.Sync;

/// <summary>同步里的一个翻译服务（mac TranslateService 的字段；Windows 专有的设置不进来）。</summary>
public sealed record SyncService(
    string Id, string Kind, string Name, bool Enabled, string? Model, string? BaseUrl, string? Protocol,
    string? Region, bool UsesDeepLX);

/// <summary>去重掉的本机自建 AI 服务：密钥从 From 搬给 To（To 在本机还没有密钥时）。</summary>
public sealed record SyncSecretMove(string From, string To);

public sealed class ServiceSyncPlan
{
    public List<SyncService> Services { get; } = new();

    public List<SyncSecretMove> SecretMoves { get; } = new();
}

public static class ServiceSync
{
    public const string Kind = "services";

    public static Dictionary<string, string> Values(IReadOnlyList<SyncService> services)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var service in services)
        {
            values.TryAdd(service.Id, Service(service));
        }

        values[SyncEngine.OrderID] = SyncEngine.OrderValue(services.Select(service => service.Id));
        return values;
    }

    /// <summary>键按字母排：aiProtocol / baseURL / id / isEnabled / kind / model / name / region / usesDeepLX。</summary>
    public static string Service(SyncService service)
    {
        var builder = new System.Text.StringBuilder("{");
        var first = true;
        void Field(string name, string value)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(name, builder);
            builder.Append(':').Append(value);
        }

        if (service.Protocol is not null)
        {
            Field("aiProtocol", SyncValues.Quote(service.Protocol));
        }

        if (service.BaseUrl is not null)
        {
            Field("baseURL", SyncValues.Quote(service.BaseUrl));
        }

        Field("id", SyncValues.Quote(service.Id));
        Field("isEnabled", service.Enabled ? "true" : "false");
        Field("kind", SyncValues.Quote(service.Kind));
        if (service.Model is not null)
        {
            Field("model", SyncValues.Quote(service.Model));
        }

        Field("name", SyncValues.Quote(service.Name));
        if (service.Region is not null)
        {
            Field("region", SyncValues.Quote(service.Region));
        }

        if (service.UsesDeepLX)
        {
            Field("usesDeepLX", "true");
        }

        return builder.Append('}').ToString();
    }

    /// <summary>第一次合时认「同一个自建 AI 服务」：协议、地址、模型一样。</summary>
    public static string? JoinKey(string value)
        => SyncValues.Read(value, root => SyncValues.Text(root, "kind") == "ai"
            ? JoinKey(SyncValues.Text(root, "aiProtocol"), SyncValues.Text(root, "baseURL"), SyncValues.Text(root, "model"))
            : null);

    private static string? JoinKey(SyncService service)
        => service.Kind == "ai" ? JoinKey(service.Protocol, service.BaseUrl, service.Model) : null;

    private static string JoinKey(string? protocol, string? baseUrl, string? model)
        => (protocol ?? string.Empty) + "\0" + (baseUrl ?? string.Empty) + "\0" + (model ?? string.Empty);

    private static SyncService? Decode(string id, string value)
    {
        var service = SyncValues.Read(value, root =>
            SyncValues.Text(root, "kind") is { Length: > 0 } kind && SyncValues.Text(root, "name") is { } name &&
            SyncValues.Text(root, "id") == id
                ? new SyncService(
                    id, kind, name, SyncValues.Flag(root, "isEnabled"), SyncValues.Text(root, "model"),
                    SyncValues.Text(root, "baseURL"),
                    // 没写协议就是没有（不补 openai）：补了编回去就多一个字段，对不上。
                    SyncValues.Text(root, "aiProtocol"), SyncValues.Text(root, "region"),
                    SyncValues.Flag(root, "usesDeepLX"))
                : null);
        return service is not null && Service(service) == value ? service : null;
    }

    public static ServiceSyncPlan? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<SyncService> current, out string? failure)
    {
        failure = null;
        var before = new Dictionary<string, SyncService>(StringComparer.Ordinal);
        foreach (var service in current)
        {
            before.TryAdd(service.Id, service);
        }

        var services = new Dictionary<string, SyncService>(before, StringComparer.Ordinal);
        IReadOnlyList<string> order = current.Select(service => service.Id).ToList();
        foreach (var (id, value) in changes)
        {
            if (id == SyncEngine.OrderID)
            {
                if (value is null)
                {
                    continue;
                }

                if (SyncValues.DecodeOrder(value) is not { } ids)
                {
                    failure = ClipSync.Unreadable;
                    return null;
                }

                order = ids;
                continue;
            }

            if (value is null)
            {
                services.Remove(id);
                continue;
            }

            if (Decode(id, value) is not { } service)
            {
                failure = ClipSync.Unreadable;
                return null;
            }

            services[id] = service;
        }

        var plan = new ServiceSyncPlan();
        // 第一次合时被去重掉的本机 AI 服务：密钥搬给留下的那个（执行时再看它在本机有没有密钥）。
        foreach (var (id, old) in before.Where(pair => !services.ContainsKey(pair.Key)))
        {
            if (JoinKey(old) is not { } key)
            {
                continue;
            }

            if (services.Values.OrderBy(kept => kept.Id, StringComparer.Ordinal)
                    .FirstOrDefault(kept => kept.Id != id && JoinKey(kept) == key) is { } match)
            {
                plan.SecretMoves.Add(new SyncSecretMove(id, match.Id));
            }
        }

        plan.Services.AddRange(SyncEngine.Arranged(services.Keys, order).Select(id => services[id]));
        return plan;
    }
}

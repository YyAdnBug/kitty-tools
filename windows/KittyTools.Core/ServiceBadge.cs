// 翻译卡和设置里的服务图标（纯函数，配单测）：有官方 logo 用 logo（Logo，照 mac ServiceTile.logo(for:)），
// 没有就是品牌色块 + 首字：内置服务用中文 / 品牌首字，AI 服务按厂商首字母。
// 颜色由界面层按厂商挑（Theme.ServiceBadge）；这里只管 logo 名和字。
namespace KittyTools.Core;

public static class ServiceBadge
{
    public static string Letter(string kind, string? protocol, string name)
    {
        return kind switch
        {
            "zhipu" => "智",
            "baidu" => "百",
            "youdao" => "有",
            "google" => "谷",
            "deepl" => "D",
            "microsoft" => "微",
            "volcengine" => "火",
            "tencent" => "腾",
            "ai" => ProtocolLetter(protocol, name),
            _ => FirstLetter(name),
        };
    }

    private static string ProtocolLetter(string? protocol, string name) => protocol switch
    {
        "azure" => "Az",
        "anthropic" => "An",
        "openai" => "Gpt",
        _ => FirstLetter(name),
    };

    private static string FirstLetter(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return "?";
        }

        var trimmed = name.Trim();
        return trimmed[..1].ToUpperInvariant();
    }

    /// <summary>
    /// 官方 logo（Resources/ServiceLogo 里的文件名，不带 .png）：内置服务按种类；AI 服务 Azure 用微软，其余按厂商——
    /// 先看补全后的服务地址、再看服务名里的关键词、都认不出而协议是 Anthropic 的算 Anthropic。认不出是谁时 null（用色块首字）。
    /// </summary>
    public static string? Logo(string kind, string? protocol, string? baseUrl, string name)
    {
        if (kind != "ai")
        {
            return kind is "zhipu" or "baidu" or "youdao" or "google" or "deepl" or "microsoft" or "volcengine" or "tencent"
                ? kind
                : null;
        }

        var aiProtocol = AiEndpoint.ParseProtocol(protocol);
        if (aiProtocol == AiProtocol.Azure)
        {
            return "microsoft";
        }

        var vendor = (AiEndpoint.Resolve(baseUrl, aiProtocol) is { } url ? AiEndpoint.VendorOf(url) : null)
            ?? AiEndpoint.VendorOfName(name)
            ?? (aiProtocol == AiProtocol.Anthropic ? AiVendor.Anthropic : null);
        return vendor?.ToString().ToLowerInvariant();
    }

    /// <summary>自带底色的满版 logo 直接裁圆角；其余只有图形，垫白底、四周留 14%（mac fullBleed）。</summary>
    public static bool IsFullBleed(string logo)
        => logo is "zhipu" or "baidu" or "youdao" or "anthropic" or "kimi" or "openrouter" or "grok" or "minimax";

    /// <summary>厂商编号：按它选徽标底色（界面里只认这几档）。</summary>
    public static string Vendor(string kind, string? protocol)
        => kind == "ai" ? "ai:" + (protocol ?? "openai") : kind;
}

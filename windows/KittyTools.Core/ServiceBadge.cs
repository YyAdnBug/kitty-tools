// 翻译卡上的服务徽标（纯函数，配单测）：内置服务用中文 / 品牌首字，AI 服务按厂商首字母。
// 颜色由界面层按厂商挑（Theme.ServiceBadge）；这里只管字。
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

    /// <summary>厂商编号：按它选徽标底色（界面里只认这几档）。</summary>
    public static string Vendor(string kind, string? protocol)
        => kind == "ai" ? "ai:" + (protocol ?? "openai") : kind;
}

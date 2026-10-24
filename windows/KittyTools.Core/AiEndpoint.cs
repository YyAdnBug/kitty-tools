// 大模型服务的地址、参数和「关思考」分档（纯函数，配单测）。
// 也按地址认厂商（关思考分档、max_tokens、服务 logo 共用）。
namespace KittyTools.Core;

public enum AiProtocol
{
    OpenAi,
    Azure,
    Anthropic,
}

public enum AiVendor
{
    OpenRouter,
    SiliconFlow,
    DeepSeek,
    Kimi,
    Qwen,
    Doubao,
    Ollama,
    Mistral,
    Grok,
    Minimax,
    Zhipu,
    Gemini,
    Anthropic,
    OpenAi,
}

public static class AiEndpoint
{
    /// <summary>
    /// OpenAI 兼容 / Azure：已含 /chat/completions 原样用；末段是 v&lt;数字&gt; 或 openai 补
    /// /chat/completions；否则补 /v1/chat/completions。Anthropic 同理对应 /messages，
    /// 默认 api.anthropic.com。没写协议补 https://。
    /// </summary>
    public static Uri? Resolve(string? raw, AiProtocol protocol)
    {
        var value = (raw ?? string.Empty).Trim();
        if (value.Length == 0 && protocol == AiProtocol.Anthropic)
        {
            value = "https://api.anthropic.com";
        }

        if (value.Length == 0)
        {
            return null;
        }

        if (!value.Contains("://", StringComparison.Ordinal))
        {
            value = "https://" + value;
        }

        while (value.EndsWith('/'))
        {
            value = value[..^1];
        }

        var suffix = protocol == AiProtocol.Anthropic ? "/messages" : "/chat/completions";
        if (value.Contains(suffix, StringComparison.OrdinalIgnoreCase))
        {
            return Uri.TryCreate(value, UriKind.Absolute, out var exact) ? exact : null;
        }

        var last = value.Split('/')[^1].ToLowerInvariant();
        var versioned = last == "openai" || (last.StartsWith('v') && IsVersionSegment(last));
        var candidate = value + (versioned ? suffix : "/v1" + suffix);
        return Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ? uri : null;
    }

    /// <summary>智谱域名上限 1024（超了直接报错）；OpenAI 官方与 Azure 不传；其余 4096。</summary>
    public static int? MaxTokens(Uri url, AiProtocol protocol)
    {
        if (protocol == AiProtocol.Azure)
        {
            return null;
        }

        return VendorOf(url) switch
        {
            AiVendor.OpenAi => null,
            AiVendor.Zhipu => 1024,
            _ => 4096,
        };
    }

    /// <summary>
    /// 关闭「思考」的参数档位（翻译不需要推理，开着会拖慢且可能占满输出额度），最后一档什么都不带。
    /// 键值都是 JSON 能直接写进去的简单类型。
    /// </summary>
    public static IReadOnlyList<IReadOnlyDictionary<string, object?>> Tiers(
        Uri url,
        AiProtocol protocol,
        string model)
    {
        static Dictionary<string, object?> Effort(string level) => new() { ["reasoning_effort"] = level };

        var disabled = new Dictionary<string, object?> { ["thinking"] = new Dictionary<string, object?> { ["type"] = "disabled" } };
        switch (protocol)
        {
            case AiProtocol.Anthropic:
                return new[] { disabled, new Dictionary<string, object?>() };
            case AiProtocol.Azure:
                return new[] { Effort("none"), Effort("minimal"), Effort("low"), new Dictionary<string, object?>() };
            default:
                if (IsLocalNetwork(url))
                {
                    var kwargs = new Dictionary<string, object?>
                    {
                        ["chat_template_kwargs"] = new Dictionary<string, object?> { ["enable_thinking"] = false },
                    };
                    var both = new Dictionary<string, object?>(kwargs) { ["reasoning_effort"] = "none" };
                    return new[] { both, kwargs, new Dictionary<string, object?>() };
                }

                return VendorOf(url) switch
                {
                    AiVendor.Zhipu or AiVendor.Kimi or AiVendor.Doubao =>
                        new[] { disabled, Effort("low"), new Dictionary<string, object?>() },
                    AiVendor.DeepSeek => new[] { disabled, new Dictionary<string, object?>() },
                    AiVendor.Qwen or AiVendor.SiliconFlow =>
                        new[] { new Dictionary<string, object?> { ["enable_thinking"] = false }, new Dictionary<string, object?>() },
                    AiVendor.OpenRouter => new[]
                    {
                        new Dictionary<string, object?> { ["reasoning"] = new Dictionary<string, object?> { ["effort"] = "none" } },
                        new Dictionary<string, object?> { ["reasoning"] = new Dictionary<string, object?> { ["effort"] = "low" } },
                        new Dictionary<string, object?>(),
                    },
                    AiVendor.Gemini => new[] { Effort("none"), Effort("minimal"), Effort("low"), new Dictionary<string, object?>() },
                    AiVendor.OpenAi => OpenAiTiers(model),
                    _ => new[] { Effort("none"), new Dictionary<string, object?>() },
                };
        }
    }

    /// <summary>按地址的 host 认厂商（不分大小写）；端口 11434 且在本机 / 局域网算 Ollama。</summary>
    public static AiVendor? VendorOf(Uri url)
    {
        var host = NormalizeHost(url);
        if (url.Port == 11434 && IsLocalNetwork(url))
        {
            return AiVendor.Ollama;
        }

        return MatchesDomain(host, AiVendor.OpenRouter) ? AiVendor.OpenRouter
            : MatchesDomain(host, AiVendor.SiliconFlow) ? AiVendor.SiliconFlow
            : MatchesDomain(host, AiVendor.DeepSeek) ? AiVendor.DeepSeek
            : MatchesDomain(host, AiVendor.Kimi) ? AiVendor.Kimi
            : MatchesDomain(host, AiVendor.Qwen) ? AiVendor.Qwen
            : MatchesDomain(host, AiVendor.Doubao) ? AiVendor.Doubao
            : MatchesDomain(host, AiVendor.Ollama) ? AiVendor.Ollama
            : MatchesDomain(host, AiVendor.Mistral) ? AiVendor.Mistral
            : MatchesDomain(host, AiVendor.Grok) ? AiVendor.Grok
            : MatchesDomain(host, AiVendor.Minimax) ? AiVendor.Minimax
            : MatchesDomain(host, AiVendor.Zhipu) ? AiVendor.Zhipu
            : MatchesDomain(host, AiVendor.Gemini) ? AiVendor.Gemini
            : MatchesDomain(host, AiVendor.Anthropic) ? AiVendor.Anthropic
            : MatchesDomain(host, AiVendor.OpenAi) ? AiVendor.OpenAi
            : null;
    }

    /// <summary>按服务地址认不出时再按服务名里的关键词认。</summary>
    public static AiVendor? VendorOfName(string name)
    {
        var lower = name.ToLowerInvariant();
        foreach (AiVendor vendor in Enum.GetValues<AiVendor>())
        {
            if (Keywords(vendor).Any(lower.Contains))
            {
                return vendor;
            }
        }

        return null;
    }

    public static bool IsOpenCode(Uri url)
    {
        var host = NormalizeHost(url);
        return host == "opencode.ai" || host.EndsWith(".opencode.ai", StringComparison.Ordinal);
    }

    /// <summary>本机或局域网地址：回环、私网 / 链路本地 IP、localhost、*.local、不带点的主机名。</summary>
    public static bool IsLocalNetwork(Uri url)
    {
        var host = NormalizeHost(url);
        if (host is "localhost" || host.EndsWith(".local", StringComparison.Ordinal) ||
            (!host.Contains('.') && !host.Contains(':')))
        {
            return true;
        }

        if (host is "::1" || host.StartsWith("fe80:", StringComparison.Ordinal) ||
            host.StartsWith("fc", StringComparison.Ordinal) || host.StartsWith("fd", StringComparison.Ordinal))
        {
            return host.Contains(':');
        }

        var parts = host.Split('.');
        if (parts.Length != 4 || parts.Any(part => !byte.TryParse(part, out _)))
        {
            return false;
        }

        var first = byte.Parse(parts[0]);
        var second = byte.Parse(parts[1]);
        return first == 127 || first == 10 || (first == 192 && second == 168) ||
               (first == 169 && second == 254) || (first == 172 && second is >= 16 and <= 31);
    }

    private static IReadOnlyList<IReadOnlyDictionary<string, object?>> OpenAiTiers(string model)
    {
        var lower = model.ToLowerInvariant();
        if (new[] { "gpt-4", "gpt-3.5", "chatgpt" }.Any(lower.StartsWith))
        {
            return new[] { new Dictionary<string, object?>() };
        }

        if (new[] { "o1", "o3", "o4" }.Any(lower.StartsWith))
        {
            return new[]
            {
                new Dictionary<string, object?> { ["reasoning_effort"] = "low" },
                new Dictionary<string, object?>(),
            };
        }

        return new[]
        {
            new Dictionary<string, object?> { ["reasoning_effort"] = "none" },
            new Dictionary<string, object?> { ["reasoning_effort"] = "minimal" },
            new Dictionary<string, object?> { ["reasoning_effort"] = "low" },
            new Dictionary<string, object?>(),
        };
    }

    private static bool MatchesDomain(string host, AiVendor vendor)
        => Domains(vendor).Any(domain => host == domain || host.EndsWith("." + domain, StringComparison.Ordinal));

    private static string NormalizeHost(Uri url)
        => url.Host.Trim('[', ']').TrimEnd('.').ToLowerInvariant();

    private static string[] Domains(AiVendor vendor) => vendor switch
    {
        AiVendor.OpenRouter => new[] { "openrouter.ai" },
        AiVendor.SiliconFlow => new[] { "siliconflow.cn", "siliconflow.com" },
        AiVendor.DeepSeek => new[] { "deepseek.com" },
        AiVendor.Kimi => new[] { "moonshot.cn", "moonshot.ai" },
        AiVendor.Qwen => new[] { "dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com" },
        AiVendor.Doubao => new[] { "volces.com" },
        AiVendor.Ollama => new[] { "ollama.com" },
        AiVendor.Mistral => new[] { "mistral.ai" },
        AiVendor.Grok => new[] { "x.ai" },
        AiVendor.Minimax => new[] { "minimax.chat", "minimaxi.com", "minimax.io" },
        AiVendor.Zhipu => new[] { "bigmodel.cn", "z.ai" },
        AiVendor.Gemini => new[] { "generativelanguage.googleapis.com" },
        AiVendor.Anthropic => new[] { "anthropic.com" },
        AiVendor.OpenAi => new[] { "openai.com" },
        _ => Array.Empty<string>(),
    };

    private static string[] Keywords(AiVendor vendor) => vendor switch
    {
        AiVendor.OpenRouter => new[] { "openrouter" },
        AiVendor.SiliconFlow => new[] { "siliconflow", "硅基" },
        AiVendor.DeepSeek => new[] { "deepseek", "深度求索" },
        AiVendor.Kimi => new[] { "kimi", "moonshot", "月之暗面" },
        AiVendor.Qwen => new[] { "qwen", "通义", "千问", "百炼", "dashscope" },
        AiVendor.Doubao => new[] { "doubao", "豆包", "火山方舟" },
        AiVendor.Ollama => new[] { "ollama" },
        AiVendor.Mistral => new[] { "mistral" },
        AiVendor.Grok => new[] { "grok", "xai" },
        AiVendor.Minimax => new[] { "minimax", "海螺" },
        AiVendor.Zhipu => new[] { "zhipu", "智谱", "glm", "bigmodel" },
        AiVendor.Gemini => new[] { "gemini" },
        AiVendor.Anthropic => new[] { "anthropic", "claude" },
        AiVendor.OpenAi => new[] { "openai", "gpt" },
        _ => Array.Empty<string>(),
    };

    private static bool IsVersionSegment(string last)
    {
        // v4、v1beta、v1beta2 这类
        if (last.Length < 2 || last[0] != 'v')
        {
            return false;
        }

        var rest = last[1..];
        if (rest.Length == 0 || !char.IsAsciiDigit(rest[0]))
        {
            return false;
        }

        return rest.All(ch => char.IsAsciiLetterOrDigit(ch));
    }
}

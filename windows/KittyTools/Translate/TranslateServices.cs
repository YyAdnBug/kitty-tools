// 翻译服务的配置列表：默认只有内置智谱（启用）；可在设置里加回内置服务或新建 AI 服务。
// 非密钥配置存 settings.json，密钥只进凭据管理器（目标名 <id>.<字段>）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class TranslateKinds
{
    public const string Zhipu = "zhipu";
    public const string Google = "google";
    public const string DeepL = "deepl";
    public const string Microsoft = "microsoft";
    public const string Ai = "ai";

    public static readonly string[] All = { Zhipu, Google, DeepL, Microsoft, Ai };

    public static string DefaultName(string kind) => kind switch
    {
        Zhipu => "智谱 GLM（免费）",
        Google => "Google 翻译",
        DeepL => "DeepL",
        Microsoft => "微软翻译",
        _ => "AI 服务",
    };

    /// <summary>内置服务要存进凭据管理器的字段；AI 服务固定是 apiKey。</summary>
    public static string SecretField(string kind) => kind switch
    {
        DeepL => "authKey",
        Microsoft => "subscriptionKey",
        _ => "apiKey",
    };

    public static string SecretLabel(string kind) => kind switch
    {
        DeepL => "Auth Key",
        Microsoft => "Key",
        _ => "API Key",
    };

    public static bool IsBuiltin(string kind) => kind is Zhipu or Google or DeepL or Microsoft;
}

internal sealed record AiPreset(string Name, AiProtocol Protocol, string BaseUrl)
{
    public TranslateServiceConfig Create() => new()
    {
        Id = "ai:" + Guid.NewGuid().ToString("N")[..8],
        Kind = TranslateKinds.Ai,
        Name = Name,
        Enabled = false,
        Model = string.Empty,
        BaseUrl = BaseUrl,
        Protocol = Protocol.ToString().ToLowerInvariant(),
    };
}

internal static class TranslatePresets
{
    public static readonly AiPreset[] Ai =
    {
        new("OpenAI", AiProtocol.OpenAi, "https://api.openai.com/v1"),
        new("DeepSeek", AiProtocol.OpenAi, "https://api.deepseek.com/v1"),
        new("通义千问", AiProtocol.OpenAi, "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        new("Kimi", AiProtocol.OpenAi, "https://api.moonshot.cn/v1"),
        new("硅基流动", AiProtocol.OpenAi, "https://api.siliconflow.cn/v1"),
        new("OpenRouter", AiProtocol.OpenAi, "https://openrouter.ai/api/v1"),
        new("Gemini", AiProtocol.OpenAi, "https://generativelanguage.googleapis.com/v1beta/openai"),
        new("Anthropic", AiProtocol.Anthropic, string.Empty),
        new("Ollama", AiProtocol.OpenAi, "http://127.0.0.1:11434/v1"),
    };

    /// <summary>智谱的两档免费纯文本模型，别的值回落第一档。</summary>
    public static string ZhipuModel(string? stored)
        => stored is "glm-4-flash" or "glm-4.7-flash" ? stored : "glm-4-flash";
}

internal sealed class TranslateServiceStore
{
    public static TranslateServiceStore? Instance { get; private set; }

    private readonly Settings _settings;

    private TranslateServiceStore(Settings settings)
    {
        _settings = settings;
        if (_settings.TranslateServices is null)
        {
            _settings.TranslateServices = new List<TranslateServiceConfig> { Builtin(TranslateKinds.Zhipu) };
        }
    }

    public static TranslateServiceStore Start(Settings settings)
    {
        Instance = new TranslateServiceStore(settings);
        return Instance;
    }

    public List<TranslateServiceConfig> Services => _settings.TranslateServices!;

    public IEnumerable<TranslateServiceConfig> Enabled => Services.Where(service => service.Enabled);

    public (Lang First, Lang Second) Languages
        => Langs.Pair(_settings.TranslateFirstLanguage, _settings.TranslateSecondLanguage);

    public void Save() => SettingsService.Save();

    public TranslateServiceConfig? Find(string id) => Services.FirstOrDefault(service => service.Id == id);

    public static TranslateServiceConfig Builtin(string kind) => new()
    {
        Id = kind,
        Kind = kind,
        Name = TranslateKinds.DefaultName(kind),
        Enabled = kind == TranslateKinds.Zhipu,
        Model = kind == TranslateKinds.Zhipu ? TranslatePresets.ZhipuModel(null) : null,
    };

    public TranslateServiceConfig AddBuiltin(string kind)
    {
        var existing = Find(kind);
        if (existing is not null)
        {
            return existing;
        }

        var service = Builtin(kind);
        Services.Add(service);
        Save();
        return service;
    }

    public TranslateServiceConfig AddAi(AiPreset preset)
    {
        var service = preset.Create();
        Services.Add(service);
        Save();
        return service;
    }

    public TranslateServiceConfig AddCustomAi()
    {
        var service = new TranslateServiceConfig
        {
            Id = "ai:" + Guid.NewGuid().ToString("N")[..8],
            Kind = TranslateKinds.Ai,
            Name = "AI 服务",
            Enabled = false,
            Model = string.Empty,
            BaseUrl = string.Empty,
            Protocol = "openai",
        };
        Services.Add(service);
        Save();
        return service;
    }

    public void Remove(string id)
    {
        var service = Find(id);
        if (service is null)
        {
            return;
        }

        if (service.Kind == TranslateKinds.Ai)
        {
            SetSecret(service, null);
        }

        Services.RemoveAll(item => item.Id == id);
        Save();
    }

    public IReadOnlyList<string> MissingBuiltins
        => new[] { TranslateKinds.Zhipu, TranslateKinds.Google, TranslateKinds.DeepL, TranslateKinds.Microsoft }
            .Where(kind => Find(kind) is null)
            .ToList();

    public string? Secret(TranslateServiceConfig service, string? field = null)
    {
        var value = Credentials.Get(Credentials.Target($"{service.Id}.{field ?? TranslateKinds.SecretField(service.Kind)}"));
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    public void SetSecret(TranslateServiceConfig service, string? value, string? field = null)
    {
        var target = Credentials.Target($"{service.Id}.{field ?? TranslateKinds.SecretField(service.Kind)}");
        if (value is null)
        {
            Credentials.Delete(target);
        }
        else
        {
            Credentials.Set(target, value);
        }
    }

    /// <summary>编译进程序集的内置智谱 key（Secrets.props 的 KittyBuiltinZhipuKey）；没有就是 null。</summary>
    public static string? BuiltinZhipuKey
    {
        get
        {
            var value = typeof(TranslateServiceStore).Assembly
                .GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
                .OfType<System.Reflection.AssemblyMetadataAttribute>()
                .FirstOrDefault(attribute => attribute.Key == "KittyBuiltinZhipuKey")
                ?.Value;
            return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        }
    }

    public bool HasAnyUsableService => Enabled.Any(service => service.Kind != TranslateKinds.Zhipu
                                                              || Secret(service) is not null
                                                              || BuiltinZhipuKey is not null);

    /// <summary>服务分发只有一个 switch（加服务 = 一个 Provider 文件 + 一个 case）。</summary>
    public static IAsyncEnumerable<string> Translate(
        TranslateServiceConfig service,
        TranslateRequest request,
        CancellationToken cancellationToken) => service.Kind switch
    {
        TranslateKinds.Zhipu => ZhipuProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Google => GoogleProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.DeepL => DeepLProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Microsoft => MicrosoftProvider.StreamAsync(service, request, cancellationToken),
        _ => AiServiceProvider.StreamAsync(service, request, cancellationToken),
    };
}

// 翻译服务的配置列表：默认只有内置智谱（启用）；可在设置里加回内置服务或新建 AI 服务。
// 非密钥配置存 settings.json，密钥只进凭据管理器（目标名 <id>.<字段>）。
// PLAN-v14：加了不用 key 的有道词典（youdaoDict，只查单词和短语）；mac 的系统翻译（apple）和以后不认识的种类
// 留在列表里（同步、导出原样带回去），翻译时不开它们的卡，设置里灰字说明（V2、V3）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class TranslateKinds
{
    public const string Zhipu = "zhipu";
    public const string Google = "google";
    public const string DeepL = "deepl";
    public const string Microsoft = "microsoft";
    public const string Baidu = "baidu";
    public const string Youdao = "youdao";
    public const string Volcengine = "volcengine";
    public const string Tencent = "tencent";
    public const string YoudaoDict = "youdaoDict";

    /// <summary>mac 的系统翻译（Translation 框架）：Windows 用不了，只认得它（V2）。</summary>
    public const string Apple = "apple";
    public const string Ai = "ai";

    public static readonly string[] All =
    {
        Zhipu, Google, DeepL, Microsoft, Baidu, Youdao, Volcengine, Tencent, YoudaoDict, Ai,
    };

    /// <summary>词典类服务（有道词典）：只查单词和短语，不当主结果、不进静默替换（mac Kind.isDictionary）。</summary>
    public static bool IsDictionary(string kind) => kind == YoudaoDict;

    /// <summary>这一版能跑的种类：内置的和 AI 服务。系统翻译、不认识的种类不开卡（V2、V3）。</summary>
    public static bool IsRunnable(string kind) => IsBuiltin(kind) || kind == Ai;

    public static string DefaultName(string kind) => kind switch
    {
        Zhipu => "智谱 GLM（免费）",
        Google => "Google 翻译",
        DeepL => "DeepL",
        Microsoft => "微软翻译",
        Baidu => "百度翻译",
        Youdao => "有道翻译",
        Volcengine => "火山翻译",
        Tencent => "腾讯翻译",
        YoudaoDict => "有道词典",
        Apple => "系统翻译",
        _ => "AI 服务",
    };

    /// <summary>
    /// 内置服务要存进凭据管理器的字段（有的是两个）；AI 服务固定是 apiKey。不用 key 的（有道词典、系统翻译）和
    /// 不认识的种类没有字段（空数组）：取第一个的地方用 SecretField，它有兜底。
    /// </summary>
    public static string[] SecretFields(string kind) => kind switch
    {
        YoudaoDict or Apple => System.Array.Empty<string>(),
        Zhipu or Google or Ai => new[] { "apiKey" },
        DeepL => new[] { "authKey" },
        Microsoft => new[] { "subscriptionKey" },
        Baidu => new[] { "appId", "secret" },
        Youdao => new[] { "appKey", "appSecret" },
        Volcengine => new[] { "accessKey", "secretKey" },
        Tencent => new[] { "secretId", "secretKey" },
        _ => System.Array.Empty<string>(),
    };

    /// <summary>第一个字段（单字段的服务的旧写法都还用它）；没有字段的种类给 apiKey（读出来总是空的，不会越界）。</summary>
    public static string SecretField(string kind) => SecretFields(kind) is { Length: > 0 } fields ? fields[0] : "apiKey";

    public static string SecretLabel(string kind, string field) => (kind, field) switch
    {
        (DeepL, _) => "Auth Key",
        (Microsoft, _) => "Key",
        (Baidu, "appId") => "App ID",
        (Baidu, _) => "密钥",
        (Youdao, "appKey") => "应用 ID",
        (Youdao, _) => "应用密钥",
        (Volcengine, "accessKey") => "Access Key",
        (Volcengine, _) => "Secret Key",
        (Tencent, "secretId") => "SecretId",
        (Tencent, _) => "SecretKey",
        _ => "API Key",
    };

    /// <summary>兼容只传种类的旧调用（标签只用于单字段服务）。</summary>
    public static string SecretLabel(string kind) => SecretLabel(kind, SecretField(kind));

    public static bool IsBuiltin(string kind)
        => kind is Zhipu or Google or DeepL or Microsoft or Baidu or Youdao or Volcengine or Tencent or YoudaoDict;
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

    /// <summary>同步落地：整份换掉服务列表（密钥不在列表里，凭据管理器的键不动）。</summary>
    public void ReplaceServices(List<TranslateServiceConfig> services)
    {
        _settings.TranslateServices = services;
        Save();
    }

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

    /// <summary>还没加的内置服务（8 个都能加回来，B11；顺序同 mac TranslateService.builtins）。</summary>
    public IReadOnlyList<string> MissingBuiltins
        => TranslateKinds.All.Where(kind => TranslateKinds.IsBuiltin(kind) && Find(kind) is null).ToList();

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

    public bool HasAnyUsableService => Enabled.Any(service => TranslateKinds.IsRunnable(service.Kind)
                                                              && (service.Kind != TranslateKinds.Zhipu
                                                                  || Secret(service) is not null
                                                                  || BuiltinZhipuKey is not null));

    /// <summary>
    /// 服务分发只有一个 switch（加服务 = 一个 Provider 文件 + 一个 case）。AI 服务明写（以前 _ 一律当 AI 服务跑）；
    /// 系统翻译和不认识的种类不该走到这里（不开卡），走到了就报配置错误。
    /// </summary>
    public static IAsyncEnumerable<string> Translate(
        TranslateServiceConfig service,
        TranslateRequest request,
        CancellationToken cancellationToken) => service.Kind switch
    {
        TranslateKinds.Zhipu => ZhipuProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Google => GoogleProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.DeepL => DeepLProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Microsoft => MicrosoftProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Baidu => BaiduProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Youdao => YoudaoProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Volcengine => VolcengineProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Tencent => TencentProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.YoudaoDict => YoudaoDictProvider.StreamAsync(service, request, cancellationToken),
        TranslateKinds.Ai => AiServiceProvider.StreamAsync(service, request, cancellationToken),
        _ => Unsupported(service),
    };

    private static async IAsyncEnumerable<string> Unsupported(TranslateServiceConfig service)
    {
        await Task.CompletedTask;
        throw TranslateError.Config(service.Kind == TranslateKinds.Apple
            ? "系统翻译只在 Mac 上能用"
            : "这一版不认识这个服务，更新后可用");
#pragma warning disable CS0162 // 迭代器要有 yield 才算迭代器
        yield break;
#pragma warning restore CS0162
    }
}

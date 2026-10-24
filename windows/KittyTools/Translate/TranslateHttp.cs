// 翻译的错误和网络请求：JSON POST、SSE 流式读取、面向用户的中文错误信息。
// 红线：错误信息和日志里不出现请求 URL、请求头和密钥。
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;

namespace KittyTools;

internal enum TranslateErrorKind
{
    /// <summary>缺密钥、密钥不对、地址或模型没填 / 不存在：重试没用，要去改设置。</summary>
    Config,
    /// <summary>连不上、超时、断网。</summary>
    Network,
    /// <summary>服务端出错、太频繁、额度用完、空结果、截断、中断。</summary>
    Service,
}

internal sealed class TranslateError : Exception
{
    public TranslateError(string message, TranslateErrorKind kind = TranslateErrorKind.Service, int? status = null)
        : base(message)
    {
        Kind = kind;
        Status = status;
    }

    public TranslateErrorKind Kind { get; }

    public int? Status { get; }

    public static TranslateError Config(string message) => new(message, TranslateErrorKind.Config);

    public static readonly TranslateError EmptyResult =
        new("服务没有返回译文（输出额度可能被思考过程占满，可换非推理模型）");

    /// <summary>流正常结束但服务说输出到上限了：半截照常显示，但不算完成。</summary>
    public static readonly TranslateError Truncated =
        new("只翻了前一部分：超出这个服务单次输出上限");

    public static readonly TranslateError Interrupted =
        new("已中断，点重试重新翻译");
}

internal static class TranslateHttp
{
    private static readonly HttpClient Shared = CreateClient(TimeSpan.FromSeconds(30));
    private static readonly HttpClient Local = CreateClient(TimeSpan.FromSeconds(180));

    private static HttpClient CreateClient(TimeSpan timeout)
    {
        var client = new HttpClient { Timeout = timeout };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue(
            "KittyTools",
            typeof(TranslateHttp).Assembly.GetName().Version?.ToString(3) ?? "0"));
        return client;
    }

    private static HttpClient ClientFor(Uri url) => AiEndpoint.IsLocalNetwork(url) ? Local : Shared;

    public static async Task<JsonDocument> SendAsync(
        Uri url,
        IReadOnlyDictionary<string, string> headers,
        JsonNode body,
        CancellationToken cancellationToken)
    {
        using var request = Build(url, headers, body);
        try
        {
            using var response = await ClientFor(url).SendAsync(request, cancellationToken);
            var text = await response.Content.ReadAsStringAsync(cancellationToken);
            JsonDocument document;
            try
            {
                document = JsonDocument.Parse(text);
            }
            catch (JsonException)
            {
                if (!response.IsSuccessStatusCode)
                {
                    throw Describe(response.StatusCode, null);
                }

                throw new TranslateError("服务返回的不是 JSON", TranslateErrorKind.Service, (int)response.StatusCode);
            }

            var serverMessage = (string?)null;
            if (!response.IsSuccessStatusCode || HasServerError(document.RootElement, out serverMessage))
            {
                throw Describe(response.StatusCode, serverMessage);
            }

            return document;
        }
        catch (TranslateError)
        {
            throw;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TranslateError("请求超时，请检查网络或服务地址", TranslateErrorKind.Network);
        }
        catch (HttpRequestException ex)
        {
            throw NetworkError(ex);
        }
    }

    /// <summary>SSE：逐行给出 data: 之后的内容（遇到 [DONE] 结束）。</summary>
    public static async IAsyncEnumerable<string> StreamAsync(
        Uri url,
        IReadOnlyDictionary<string, string> headers,
        JsonNode body,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        using var request = Build(url, headers, body);
        HttpResponseMessage? response = null;
        Stream? stream = null;
        StreamReader? reader = null;
        try
        {
            try
            {
                response = await ClientFor(url).SendAsync(
                    request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new TranslateError("请求超时，请检查网络或服务地址", TranslateErrorKind.Network);
            }
            catch (HttpRequestException ex)
            {
                throw NetworkError(ex);
            }

            if (!response.IsSuccessStatusCode)
            {
                var errorText = await response.Content.ReadAsStringAsync(cancellationToken);
                string? serverMessage = null;
                try
                {
                    using var document = JsonDocument.Parse(errorText);
                    HasServerError(document.RootElement, out serverMessage);
                }
                catch (JsonException)
                {
                    // 不是 JSON 的错误体：只按状态码说。
                }

                throw Describe(response.StatusCode, serverMessage);
            }

            stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            reader = new StreamReader(stream, Encoding.UTF8);
            while (true)
            {
                string? line;
                try
                {
                    line = await reader.ReadLineAsync(cancellationToken);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    throw new TranslateError("连接中断了，请重试", TranslateErrorKind.Network);
                }
                catch (IOException)
                {
                    throw new TranslateError("连接中断了，请重试", TranslateErrorKind.Network);
                }

                if (line is null)
                {
                    yield break;
                }

                if (!Sse.TryPayload(line, out var payload) || payload.Length == 0)
                {
                    continue;
                }

                if (Sse.IsDone(payload))
                {
                    yield break;
                }

                yield return payload;
            }
        }
        finally
        {
            reader?.Dispose();
            stream?.Dispose();
            response?.Dispose();
        }
    }

    /// <summary>把一档「关思考」参数并进请求体（键都是简单的字符串 / 布尔 / 嵌套字典）。</summary>
    public static void Apply(JsonNode body, IReadOnlyDictionary<string, object?> extra)
    {
        foreach (var (key, value) in extra)
        {
            body[key] = ToNode(value);
        }
    }

    public static Dictionary<string, string> OpenCodeHeaders(Uri url)
    {
        if (!AiEndpoint.IsOpenCode(url))
        {
            return new Dictionary<string, string>();
        }

        return new Dictionary<string, string>
        {
            ["x-opencode-session"] = OpenCodeSession,
            ["User-Agent"] = $"KittyTools/{typeof(TranslateHttp).Assembly.GetName().Version?.ToString(3) ?? "0"}",
        };
    }

    public static string? ServerMessage(JsonElement root)
        => HasServerError(root, out var message) ? message : null;

    private static readonly string OpenCodeSession = Guid.NewGuid().ToString();

    private static HttpRequestMessage Build(
        Uri url,
        IReadOnlyDictionary<string, string> headers,
        JsonNode body)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        foreach (var (name, value) in headers)
        {
            request.Headers.TryAddWithoutValidation(name, value);
        }

        foreach (var (name, value) in OpenCodeHeaders(url))
        {
            request.Headers.TryAddWithoutValidation(name, value);
        }

        return request;
    }

    private static bool HasServerError(JsonElement root, out string? message)
    {
        message = null;
        if (root.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        if (root.TryGetProperty("error", out var error))
        {
            if (error.ValueKind == JsonValueKind.Null)
            {
                return false;
            }

            if (error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var nested) &&
                nested.ValueKind == JsonValueKind.String)
            {
                message = nested.GetString();
                return true;
            }

            if (error.ValueKind == JsonValueKind.String)
            {
                var text = error.GetString();
                if (!string.IsNullOrEmpty(text))
                {
                    message = text;
                    return true;
                }
            }

            if (root.TryGetProperty("message", out var top) && top.ValueKind == JsonValueKind.String)
            {
                message = top.GetString();
            }

            return true;
        }

        return false;
    }

    private static TranslateError Describe(HttpStatusCode status, string? serverMessage)
    {
        var code = (int)status;
        var kind = code is 401 or 403 or 404 ? TranslateErrorKind.Config : TranslateErrorKind.Service;
        var text = code switch
        {
            401 or 403 => "密钥无效或没有权限",
            404 => "服务地址或模型不存在",
            429 => "请求太频繁或额度已用完",
            >= 500 => $"服务暂时不可用（{code}）",
            _ => $"请求失败（{code}）",
        };
        if (!string.IsNullOrWhiteSpace(serverMessage))
        {
            var clipped = serverMessage.Length > 160 ? serverMessage[..160] : serverMessage;
            text = $"{text}：{clipped}";
        }

        return new TranslateError(text, kind, code);
    }

    private static TranslateError NetworkError(HttpRequestException ex)
    {
        if (ex.InnerException is SocketException socket)
        {
            return socket.SocketErrorCode switch
            {
                SocketError.HostNotFound or SocketError.NoData => new TranslateError("连不上服务地址", TranslateErrorKind.Network),
                SocketError.ConnectionRefused => new TranslateError("服务没有在监听（连接被拒绝）", TranslateErrorKind.Network),
                SocketError.NetworkUnreachable or SocketError.HostUnreachable =>
                    new TranslateError("网络不可用", TranslateErrorKind.Network),
                _ => new TranslateError("网络错误，请检查连接", TranslateErrorKind.Network),
            };
        }

        return new TranslateError("网络不可用", TranslateErrorKind.Network);
    }

    private static JsonNode? ToNode(object? value) => value switch
    {
        null => null,
        JsonNode node => node,
        string text => JsonValue.Create(text),
        bool flag => JsonValue.Create(flag),
        int number => JsonValue.Create(number),
        long number => JsonValue.Create(number),
        double number => JsonValue.Create(number),
        IReadOnlyDictionary<string, object?> map => MapToNode(map),
        _ => JsonValue.Create(value.ToString()),
    };

    private static JsonObject MapToNode(IReadOnlyDictionary<string, object?> map)
    {
        var node = new JsonObject();
        foreach (var (key, value) in map)
        {
            node[key] = ToNode(value);
        }

        return node;
    }
}

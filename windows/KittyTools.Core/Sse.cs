// SSE 行解析（纯函数，配单测）：只认 `data:` 行，[DONE] 结束；兼容 CRLF 和行首空格。
namespace KittyTools.Core;

public static class Sse
{
    public static bool TryPayload(string line, out string payload)
    {
        payload = string.Empty;
        if (line.Length == 0)
        {
            return false;
        }

        var trimmedEnd = line.TrimEnd('\r', '\n');
        if (!trimmedEnd.StartsWith("data:", StringComparison.Ordinal))
        {
            return false;
        }

        payload = trimmedEnd[5..].Trim();
        return true;
    }

    public static bool IsDone(string payload) => payload == "[DONE]";
}

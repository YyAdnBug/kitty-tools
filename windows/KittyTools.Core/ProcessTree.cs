// 剪贴板来源的进程归属（纯函数，配单测，REVIEW R6）：
// 从内嵌网页（WebView2）里复制时，剪贴板拥有者是 msedgewebview2.exe 这类子进程，
// 要顺着父进程往上找到第一个"像主程序"的进程，来源才显示成 Teams / Outlook 而不是 WebView2。
namespace KittyTools.Core;

public static class ProcessTree
{
    /// <summary>这些进程只是宿主 / 子进程，显示来源时跳过它们。</summary>
    private static readonly string[] Embedders =
    {
        "msedgewebview2.exe",
        "applicationframehost.exe",
        "wwahost.exe",
        "webviewhost.exe",
    };

    public static bool IsEmbedder(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        var trimmed = name.Trim();
        return Embedders.Any(host => string.Equals(host, trimmed, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// 从一个进程往上找第一个不是宿主 / 子进程的进程号；找不到父进程时返回当前这个。
    /// <paramref name="processes"/>：进程号 → （父进程号, 进程文件名）。
    /// </summary>
    public static uint Resolve(uint pid, IReadOnlyDictionary<uint, (uint Parent, string Name)> processes)
    {
        var current = pid;
        for (var hop = 0; hop < 16; hop++)
        {
            if (!processes.TryGetValue(current, out var entry) || !IsEmbedder(entry.Name))
            {
                return current;
            }

            if (entry.Parent == 0 || entry.Parent == current)
            {
                return current;
            }

            current = entry.Parent;
        }

        return current;
    }
}

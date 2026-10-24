// 剪贴板来源过滤（纯函数）：设置里「不记录的应用」按 exe 名比，不分大小写。
// 允许写 KeePass 或 KeePass.exe；带路径的只取文件名。
namespace KittyTools.Core;

public static class ClipboardSourceRules
{
    public static bool IsExcluded(string? executablePath, IEnumerable<string> excluded)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            return false;
        }

        var fileName = Path.GetFileName(executablePath);
        var bareName = Path.GetFileNameWithoutExtension(executablePath);
        foreach (var entry in excluded)
        {
            if (string.IsNullOrWhiteSpace(entry))
            {
                continue;
            }

            var probe = entry.Trim();
            if (string.Equals(fileName, probe, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(bareName, probe, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(fileName, probe + ".exe", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}

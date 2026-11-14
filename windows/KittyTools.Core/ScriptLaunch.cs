// 跑脚本时的几样纯函数（PLAN-v18 L1 / D7，mac ScriptCommand.environment / ScriptRunner；配单测）：
// - cmd 的命令行：/d /s /c ""脚本" "参数""（/s 让 cmd 只去掉最外面一对引号，脚本路径带空格、参数带 & | < > 也不坏）；
// - 给脚本的环境：继承本进程的（Windows 的程序靠 SystemRoot、APPDATA 这些），PATH 换成注册表里此刻的（系统 + 用户，
//   相当于 mac 从登录 shell 读：装了新工具不用重启 Kitty），再加 KITTY_SCRIPT_DIR、KITTY_DATA_DIR、KITTY_VERSION；
//   .py 加 PYTHONIOENCODING=utf-8（输出按 UTF-8 读）；存成 UTF-8 的 .cmd / .bat 先 chcp 65001 再跑、输出按 UTF-8 读
//   （cmd 按 OEM 代码页读脚本，VS Code 这类存的 UTF-8 批处理里的中文会乱）；别的按 OEM 代码页读（App 侧）。
// ponytail: PowerShell 5.1 读不带 BOM 的 UTF-8 .ps1 当 ANSI，里面写的中文会乱；输出按 OEM 读，GBK 外的字（emoji）出不来。
// 说明里写「.ps1 存成 UTF-8 带 BOM」；要彻底就改成 pwsh（7.x 默认 UTF-8），但那要用户另装。
namespace KittyTools.Core;

public static class ScriptLaunch
{
    /// <summary>cmd /d /s /c 后面那一整段：脚本和参数各自括引号（里面的 " 写成 ""）。</summary>
    public static string CmdArguments(string script, IReadOnlyList<string> arguments, bool utf8 = false)
    {
        static string Quote(string text) => "\"" + text.Replace("\"", "\"\"") + "\"";
        return "/d /s /c \"" + (utf8 ? "chcp 65001 >nul & " : string.Empty) +
               string.Join(" ", new[] { Quote(script) }.Concat(arguments.Select(Quote))) + "\"";
    }

    /// <summary>文件开头是 UTF-8（带 BOM，或者有非 ASCII 的字、又全是合法的 UTF-8）。纯 ASCII 的算不是（哪种都一样）。</summary>
    public static bool LooksUtf8(ReadOnlySpan<byte> head)
    {
        if (head.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
        {
            return true;
        }

        var any = false;
        for (var index = 0; index < head.Length; index++)
        {
            var value = head[index];
            if (value < 0x80)
            {
                continue;
            }

            var length = value is >= 0xF0 and < 0xF8 ? 4 : value is >= 0xE0 and < 0xF0 ? 3 : value is >= 0xC2 and < 0xE0 ? 2 : 0;
            if (length == 0)
            {
                return false;
            }

            for (var next = 1; next < length; next++)
            {
                // 读到的开头截断在半个字上：不算错
                if (index + next >= head.Length)
                {
                    return true;
                }

                if ((head[index + next] & 0xC0) != 0x80)
                {
                    return false;
                }
            }

            any = true;
            index += length - 1;
        }

        return any;
    }

    /// <summary>注册表里的系统 PATH 和用户 PATH 拼起来（系统在前，%变量% 由调用方展开），去掉空的和重复的（不分大小写）。</summary>
    public static string JoinPath(string? machine, string? user)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var parts = new List<string>();
        foreach (var part in $"{machine};{user}".Split(';'))
        {
            var trimmed = part.Trim();
            if (trimmed.Length > 0 && seen.Add(trimmed.TrimEnd('\\')))
            {
                parts.Add(trimmed);
            }
        }

        return string.Join(";", parts);
    }

    /// <summary>给脚本的环境：继承的 + PATH（注册表里此刻的；读不到用继承的）+ KITTY_*；.py 另加 PYTHONIOENCODING。</summary>
    public static Dictionary<string, string> Environment(
        IReadOnlyDictionary<string, string> inherited, string? path, ScriptCommand script, string dataDirectory, string version)
    {
        var environment = new Dictionary<string, string>(inherited, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(path))
        {
            environment["PATH"] = path;
        }

        environment["KITTY_SCRIPT_DIR"] = script.Folder;
        environment["KITTY_DATA_DIR"] = dataDirectory;
        environment["KITTY_VERSION"] = version;
        if (script.Path.EndsWith(".py", StringComparison.OrdinalIgnoreCase))
        {
            environment["PYTHONIOENCODING"] = "utf-8";
        }

        return environment;
    }

    /// <summary>这个脚本的输出按 UTF-8 读：.py（设了 PYTHONIOENCODING）、存成 UTF-8 的批处理（chcp 65001 了）；别的按 OEM 代码页。</summary>
    public static bool OutputIsUtf8(ScriptCommand script, bool utf8File)
        => script.Path.EndsWith(".py", StringComparison.OrdinalIgnoreCase) || (utf8File && IsBatch(script.Path));

    public static bool IsBatch(string path)
        => path.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);
}

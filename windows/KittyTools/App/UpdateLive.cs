// `--update-live=<版本>`：对着真 GitHub 走一遍 App 内更新的下载和校验（不解压、不安装、不碰安装目录）。
// 用的是正常 Release 那套白名单（不是 --update-test），所以只有真地址才有的东西——跳转到 release-assets、
// 地址里的 %20 / %2B 转义——都会碰到。0.1.0 / 0.1.1 的更新一点就失败，就是这一路没人真走过（UpdateTrust.NextHop）。
// 结果写到 %TEMP%\kitty-update-live\report.txt（不写 URL），退出码 0 = 下载到了、sha256 对得上。发版前跑一次，
// 版本填已经发出去的那一版就行（比如 --update-live=0.1.1）。在 WinUI / 单实例初始化之前执行。
using System.Runtime.InteropServices;
using System.Text;
using KittyTools.Core;

namespace KittyTools;

internal static class UpdateLive
{
    public const string ArgumentPrefix = "--update-live=";

    public static bool IsRequested(string[] args)
        => args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static int Run(string[] args)
    {
        var version = args.First(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase))[ArgumentPrefix.Length..];
        var root = Path.Combine(Path.GetTempPath(), "kitty-update-live");
        var ok = false;
        string detail;
        try
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }

            Directory.CreateDirectory(root);
            var architecture = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
            var asset = $"KittyTools-{version}-windows-{architecture}.zip";
            var url = $"https://github.com/YyAdnBug/kitty-tools/releases/download/windows-v{version}/{asset}";
            var zip = Path.Combine(root, asset);
            UpdateHttp.DownloadAsync(url, zip, null).GetAwaiter().GetResult();
            var hashText = UpdateHttp.GetTextAsync(url + ".sha256").GetAwaiter().GetResult();
            var expected = UpdateHash.ExpectedFor(hashText, asset);
            ok = expected is not null && UpdateHash.FileMatches(zip, expected);
            detail = ok ? $"下载 {new FileInfo(zip).Length} 字节，sha256 对得上" : "sha256 对不上";
        }
        catch (Exception ex)
        {
            detail = $"{ex.GetType().Name}: {ex.Message}";
        }

        var text = $"version={version} testMode={UpdateHttp.TestMode} ok={ok} {detail}";
        try
        {
            Directory.CreateDirectory(root);
            File.WriteAllText(Path.Combine(root, "report.txt"), text + Environment.NewLine,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch
        {
            // 报告写不进去，就只看退出码。
        }

        return ok ? 0 : 1;
    }
}

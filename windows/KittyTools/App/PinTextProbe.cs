// PLAN-v26 S8 的自检（只在测试档）：`--pin-text-probe=<目录>`。把一段中英文排成文字卡钉到屏幕上，让钉图自己认字、全选、再选中第二行，
// 记下认出几个词、选中的字和原文对不对得上，单独抓这张钉图存成 pin-select.png（只抓自己的窗口）。跑完就退。
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class PinTextProbe
{
    public const string ArgumentPrefix = "--pin-text-probe=";

    private const string Sample = "钉图上的字可以直接选\nSelect words on a pinned shot";

    public static string? DirectoryFrom(string[] args)
        => Paths.IsTestProfile && args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase)) is { } argument
            ? Path.GetFullPath(argument[ArgumentPrefix.Length..])
            : null;

    public static async Task RunAsync(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            await PinHost.PinTextAsync(Sample);
            await Task.Delay(800);
            if (PinHost.Last is not { } pin)
            {
                Log.Warn("pin-text-probe no-pin");
                return;
            }

            var all = await pin.ProbeSelectAsync(line: null);
            var second = await pin.ProbeSelectAsync(line: 1);
            await Task.Delay(300);
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(pin);
            var scale = pin.Content?.XamlRoot?.RasterizationScale ?? 1.0;
            if (await WindowShadowShot.CaptureAsync(hwnd, scale) is { } png)
            {
                await File.WriteAllBytesAsync(Path.Combine(directory, "pin-select.png"), png);
            }

            // 自己的样本字，写进测试目录对着看（不进日志）
            await File.WriteAllTextAsync(Path.Combine(directory, "pin-select.txt"), all + "\n---\n" + second);
            static string Squash(string text) => new(text.Where(c => !char.IsWhiteSpace(c)).ToArray());
            var expected = Squash(Sample);
            Log.Info($"pin-text-probe words={pin.ProbeWordCount} all-match={Squash(all) == expected} all-length={all.Length} " +
                     $"chinese-match={Squash(all.Split('\n')[0]) == Squash(Sample.Split('\n')[0])} " +
                     $"second-is-line-two={all.Split('\n').Length == 2 && second == all.Split('\n')[1]}");
        }
        catch (Exception ex)
        {
            Log.Error("pin-text-probe failed", ex);
        }
        finally
        {
            Log.Info("pin-text-probe done");
            Environment.Exit(0);
        }
    }
}

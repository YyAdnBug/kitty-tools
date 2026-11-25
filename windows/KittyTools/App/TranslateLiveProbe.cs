// PLAN-v26 第 3 批的联网自检（只在测试档）：`--translate-live-probe=<目录>`，用内置智谱真的请求：
// 1. 一句中文译成 30 种里的另外 29 种（简体中文那一条换成英文原文），每种记字数、本地检测认不认得出是那种语言；
// 2. 一段 5000 字以上的中文按 LongText 切开依次翻成英文：记段数、有没有截断、译文和原文的字数比；
// 3. 打开讲解的一句英文译成中文（浮窗里的请求）：看有没有「重点词汇」「句型」两段；
// 4. 同一句不讲解时、附加要求「译文末尾加上（完）」：看末尾。
// 原文、译文只写进 <目录>\report.md（测试目录，不进日志）；日志只记每一项成没成和耗时。跑完就退。
using System.Diagnostics;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class TranslateLiveProbe
{
    public const string ArgumentPrefix = "--translate-live-probe";

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        var path = argument is not null && argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return argument is null ? null : string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-translate-live") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 联网翻译自检（内置智谱）\n\n");
        try
        {
            await Task.Delay(1500);
            var service = TranslateServiceStore.Builtin(TranslateKinds.Zhipu);

            report.Append("## 30 种语言\n\n| 目标 | 字数 | 检测 | 毫秒 | 译文开头 |\n|---|---|---|---|---|\n");
            var ok = 0;
            // KITTY_TRANSLATE_LIVE_ONLY=long：不跑 30 种语言那一项
            foreach (var lang in Environment.GetEnvironmentVariable("KITTY_TRANSLATE_LIVE_ONLY") is null ? Enum.GetValues<Lang>() : Array.Empty<Lang>())
            {
                var source = lang == Lang.ZhHans ? "The weather is very nice today, let's take a walk in the park." : "今天天气很好，我们去公园散步吧。";
                var from = lang == Lang.ZhHans ? Lang.En : Lang.ZhHans;
                var (text, ms, error) = await RunAsync(service, new TranslateRequest(source, from, lang));
                var detected = text.Length > 0 ? Langs.Detect(text, new[] { lang }) : null;
                if (text.Length > 0)
                {
                    ok++;
                }

                Log.Info($"translate-live lang={lang.Code()} ok={text.Length > 0} ms={ms}{(error is null ? string.Empty : " error=" + error)}");
                report.Append($"| {lang.Title()} | {text.Length} | {detected?.Code() ?? "-"} | {ms} | {Cell(text)}{(error is null ? string.Empty : " **" + error + "**")} |\n");
            }

            report.Append($"\n成了 {ok} / 30。\n\n## 长文分段\n\n");
            var paragraph = "长文分段翻译要把每一段都翻完。原文估出来的译文超过输出上限的六成时，按段、按句切开，在同一张卡里依次翻、接着显示。" +
                            "某一段被截断或出错就停在那里，卡片照常显示半截，并标出只翻了前一部分。";
            var longText = string.Join("\n\n", Enumerable.Range(1, 50).Select(index => $"第 {index} 段：{paragraph}"));
            var pieces = LongText.Split(longText, LongText.Budget(ZhipuProvider.MaxTokens));
            var (whole, longMs, longError) = await RunAsync(service, new TranslateRequest(longText, Lang.ZhHans, Lang.En));
            var lastIndex = whole.LastIndexOf("50", StringComparison.Ordinal);
            Log.Info($"translate-live long chars={longText.Length} pieces={pieces.Count} out={whole.Length} ms={longMs}{(longError is null ? string.Empty : " error=" + longError)}");
            report.Append($"- 原文 {longText.Length} 字，切成 {pieces.Count} 段；译文 {whole.Length} 字，{longMs} ms；{(longError is null ? "没截断、没出错" : "**" + longError + "**")}；" +
                          $"译文里{(lastIndex >= 0 ? "有" : "没有")}「50」（最后一段的段号）。\n- 译文末尾：{Cell(whole.Length > 200 ? whole[^200..] : whole)}\n\n## 讲解\n\n");

            const string sentence = "The committee has yet to decide whether the proposal is worth pursuing.";
            var explaining = TranslateServiceStore.Builtin(TranslateKinds.Zhipu);
            explaining.ExplainsSentences = true;
            var (explained, explainMs, explainError) = await RunAsync(explaining,
                new TranslateRequest(sentence, Lang.En, Lang.ZhHans, Explains: true, InPanel: true));
            var sections = explained.Contains("重点词汇", StringComparison.Ordinal) && explained.Contains("句型", StringComparison.Ordinal);
            Log.Info($"translate-live explain ok={sections} ms={explainMs}{(explainError is null ? string.Empty : " error=" + explainError)}");
            report.Append($"- 有「重点词汇」「句型」两段：{sections}（{explainMs} ms）\n\n```\n{explained}\n```\n\n## 附加要求\n\n");

            var extra = TranslateServiceStore.Builtin(TranslateKinds.Zhipu);
            extra.ExtraPrompt = "译文末尾加上（完）";
            var (plain, plainMs, plainError) = await RunAsync(extra, new TranslateRequest(sentence, Lang.En, Lang.ZhHans, InPanel: true));
            var (outside, _, _) = await RunAsync(extra, new TranslateRequest(sentence, Lang.En, Lang.ZhHans));
            Log.Info($"translate-live extra in-panel={plain.TrimEnd().EndsWith("（完）", StringComparison.Ordinal)} outside={outside.TrimEnd().EndsWith("（完）", StringComparison.Ordinal)} ms={plainMs}");
            report.Append($"- 浮窗里（接上附加要求）：{Cell(plain)}{(plainError is null ? string.Empty : " **" + plainError + "**")}\n- 不在浮窗里（不接）：{Cell(outside)}\n");
        }
        catch (Exception ex)
        {
            report.Append($"\n出错 {ex.GetType().Name}\n");
        }
        finally
        {
            await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
            Log.Info("translate-live done");
            Environment.Exit(0);
        }
    }

    private static async Task<(string Text, long Ms, string? Error)> RunAsync(TranslateServiceConfig service, TranslateRequest request)
    {
        var watch = Stopwatch.StartNew();
        var latest = string.Empty;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
            await foreach (var piece in TranslateServiceStore.Translate(service, request, cts.Token))
            {
                latest = piece;
            }

            return (StreamingText.StripSourceTags(latest), watch.ElapsedMilliseconds, null);
        }
        catch (Exception ex)
        {
            return (latest, watch.ElapsedMilliseconds, ex is TranslateError error ? error.Message : ex.GetType().Name);
        }
    }

    private static string Cell(string text)
    {
        var line = text.ReplaceLineEndings(" ").Replace("|", "\\|", StringComparison.Ordinal);
        return line.Length > 80 ? line[..80] + "…" : line;
    }
}

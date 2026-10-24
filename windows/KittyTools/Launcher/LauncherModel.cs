// 启动器的结果来源（PLAN §8 的顺序）和动作：
// 直达网址 / 路径 → 计算结果 → 关键词（cb、fy、网页搜索）→ 应用 / 设置页 / 系统命令 / 本 App 动作（按匹配分）
// → 网页搜索兜底。空查询列「常用」8 行（按全局使用分）。打开成功才记使用。
using System.Diagnostics;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class LauncherModel
{
    public static LauncherModel? Instance { get; private set; }

    private readonly List<LauncherItem> _settings = SettingsPages.Items();
    private readonly List<LauncherItem> _commands = SystemCommands.Items();
    private readonly List<LauncherItem> _actions = LauncherActions.Items();
    private string? _armed;
    private string _lastQuery = string.Empty;

    public static LauncherModel Start()
    {
        Instance = new LauncherModel();
        return Instance;
    }

    public IReadOnlyList<LauncherItem> Results(string query)
    {
        if (query.Trim() != _lastQuery)
        {
            _armed = null;
            _lastQuery = query.Trim();
        }

        if (string.IsNullOrWhiteSpace(query))
        {
            return Frequent();
        }

        var items = new List<LauncherItem>();
        items.AddRange(DirectItems.ItemsFor(query));
        if (Calculator.ItemFor(query) is { } calculation)
        {
            items.Add(calculation);
        }

        var keyword = KeywordItem(query);
        if (keyword is not null)
        {
            items.Add(keyword);
        }

        var local = AppsAndBuiltins(query);
        items.AddRange(local);

        if (items.Count == 0)
        {
            items.AddRange(WebSearch.FallbackItems(query, Engines));
        }

        return items;
    }

    public bool IsArmed(LauncherItem item) => item.Kind == LauncherKind.Command && _armed == item.Target;

    public string SubtitleFor(LauncherItem item)
        => IsArmed(item) ? SystemCommands.ConfirmSubtitle : item.Subtitle;

    /// <summary>执行一条结果；target 是启动器打开前的那个窗口（粘贴计算结果用）。</summary>
    public bool Execute(LauncherItem item, bool control, bool shift, Windows.Win32.Foundation.HWND target, out string? error)
    {
        error = null;
        switch (item.Kind)
        {
            case LauncherKind.Command:
                if (SystemCommands.NeedsConfirmation(item.Target) && _armed != item.Target)
                {
                    _armed = item.Target;
                    return false;
                }

                _armed = null;
                if (!SystemCommands.Execute(item.Target, out var commandError))
                {
                    error = string.IsNullOrEmpty(commandError) ? "系统没有接受这个命令" : commandError;
                    return false;
                }

                Record(item, _lastQuery);
                return true;

            case LauncherKind.Action:
                if (item.Target.StartsWith("cb:", StringComparison.Ordinal))
                {
                    OverlayHost.Show(OverlayKind.Clipboard);
                    OverlayHost.SetClipboardQuery(item.Payload ?? string.Empty);
                }
                else if (item.Target.StartsWith("fy:", StringComparison.Ordinal))
                {
                    TranslateHost.ShowText(item.Payload ?? string.Empty);
                }
                else
                {
                    LauncherActions.Execute(item.Target);
                }

                if (!item.Target.StartsWith("cb:", StringComparison.Ordinal) &&
                    !item.Target.StartsWith("fy:", StringComparison.Ordinal))
                {
                    Record(item, _lastQuery);
                }

                return true;

            case LauncherKind.Calculation:
                var payload = item.Payload ?? item.Title;
                if (control)
                {
                    if (!ClipboardWriter.WriteText(payload))
                    {
                        error = "剪贴板被别的程序占着";
                        return false;
                    }

                    ClipboardService.Instance?.MarkOwnWrite();
                    ClipboardService.Instance?.Store.RecordOwnText(payload);
                    NoticeHost.Show("已复制结果", payload, NoticeTone.Normal);
                }
                else
                {
                    Paster.PasteText(target, payload);
                }

                Record(item, _lastQuery);
                return true;

            case LauncherKind.App:
                if (control && shift)
                {
                    if (item.Target.StartsWith(@"shell:AppsFolder\", StringComparison.Ordinal))
                    {
                        error = "商店应用不能用管理员身份运行";
                        return false;
                    }

                    if (!Start(item.Target, "runas", out var adminError))
                    {
                        error = adminError;
                        return false;
                    }
                }
                else if (control)
                {
                    if (item.Target.StartsWith(@"shell:AppsFolder\", StringComparison.Ordinal))
                    {
                        error = "商店应用没有文件位置";
                        return false;
                    }

                    Reveal(item.Target);
                }
                else if (!Start(item.Target, null, out var startError))
                {
                    error = startError;
                    return false;
                }

                Record(item, _lastQuery);
                return true;

            case LauncherKind.Setting:
            case LauncherKind.Url:
            case LauncherKind.Search:
            case LauncherKind.Path:
                if (!Start(item.Target, null, out var openError))
                {
                    error = openError;
                    return false;
                }

                if (item.Kind != LauncherKind.Search)
                {
                    Record(item, _lastQuery);
                }

                return true;

            default:
                error = "这一项还不能打开";
                return false;
        }
    }

    public void Record(LauncherItem item, string query)
    {
        LauncherUsageStore.Instance?.Record(item, query, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }

    public IReadOnlyList<SearchEngine> Engines
        => SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults();

    private LauncherItem? KeywordItem(string query)
    {
        var text = query.Trim();
        if (text.StartsWith("cb ", StringComparison.OrdinalIgnoreCase) && text.Length > 3)
        {
            var term = text[3..].Trim();
            return new LauncherItem
            {
                Kind = LauncherKind.Action,
                Target = "cb:" + term,
                Title = $"在剪贴板里搜索「{term}」",
                Subtitle = "剪贴板历史",
                Payload = term,
            };
        }

        if (text.StartsWith("fy ", StringComparison.OrdinalIgnoreCase) && text.Length > 3)
        {
            var term = text[3..].Trim();
            return new LauncherItem
            {
                Kind = LauncherKind.Action,
                Target = "fy:" + term,
                Title = $"翻译「{term}」",
                Subtitle = "翻译",
                Payload = term,
            };
        }

        return WebSearch.KeywordItem(query, Engines);
    }

    private List<LauncherItem> AppsAndBuiltins(string query)
    {
        var all = new List<LauncherItem>();
        if (AppCatalog.Instance is { } catalog)
        {
            all.AddRange(catalog.Apps);
        }

        all.AddRange(_settings);
        all.AddRange(_commands);
        all.AddRange(_actions);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        return LauncherMatch.Rank(all, query, item =>
            LauncherUsageStore.Instance?.Boost(item, query, now) ?? default);
    }

    private List<LauncherItem> Frequent()
    {
        var store = LauncherUsageStore.Instance;
        if (store is null)
        {
            return new List<LauncherItem>();
        }

        var result = new List<LauncherItem>();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var row in store.Top(8, now))
        {
            if (Restore(row) is { } item)
            {
                result.Add(item);
            }
        }

        return result;
    }

    private static LauncherItem? Restore(LauncherUsageRow row)
    {
        var kind = LauncherUsageStore.KindFromText(row.Kind);
        switch (kind)
        {
            case LauncherKind.App:
                return AppCatalog.Instance?.Find(row.Target);
            case LauncherKind.Setting:
                return SettingsPages.Find(row.Target);
            case LauncherKind.Command:
                return SystemCommands.Find(row.Target);
            case LauncherKind.Action:
                return LauncherActions.Find(row.Target);
            case LauncherKind.Path:
                return DirectItems.ExistingPathFrom(row.Target) is null
                    ? null
                    : new LauncherItem
                    {
                        Kind = LauncherKind.Path,
                        Target = row.Target,
                        Title = row.Title,
                        Subtitle = row.Target,
                    };
            case LauncherKind.Calculation:
                return Calculator.ItemFor(row.Target);
            default:
                return new LauncherItem
                {
                    Kind = kind,
                    Target = row.Target,
                    Title = row.Title,
                    Subtitle = kind == LauncherKind.Url ? "在浏览器中打开" : "网页搜索",
                };
        }
    }

    private static bool Start(string target, string? verb, out string? error)
    {
        error = null;
        try
        {
            var info = new ProcessStartInfo(target) { UseShellExecute = true };
            if (verb is not null)
            {
                info.Verb = verb;
            }

            Process.Start(info);
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.start-failed {ex.GetType().Name}");
            error = verb == "runas" ? "没能以管理员身份运行" : "打不开这一项";
            return false;
        }
    }

    private static void Reveal(string path)
    {
        try
        {
            var target = path;
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{target}\"")
            {
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.reveal-failed {ex.GetType().Name}");
        }
    }
}

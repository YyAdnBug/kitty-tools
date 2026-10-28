// 翻译历史的导出和清空（照 mac HistoryMenu，PLAN-v9-translate F19）：浮窗「⋯」菜单、历史 Ctrl+K / 右键、设置 › 翻译三处共用。
// 导出四种（全部 / 只收藏 × CSV / Anki TSV）：CSV 带 BOM（Excel 才认 UTF-8），TSV 不带；没东西可导、写失败、导出了几条都用轻提示说。
// 清空只清普通历史，收藏（生词本）留着；确认框由这里弹。
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal static class HistoryMenu
{
    /// <summary>四种导出（标题、动作）：菜单按这张表排，三处一样。</summary>
    public static IEnumerable<(bool FavoritesOnly, bool Anki, string Title)> Exports
        => HistoryExport.Choices.Select(choice =>
            (choice.FavoritesOnly, choice.Anki, HistoryExport.ScopeTitle(choice.FavoritesOnly) + " · " + HistoryExport.FormatTitle(choice.Anki)));

    /// <param name="owner">文件对话框挂在哪扇窗上。</param>
    public static async Task ExportAsync(Microsoft.UI.WindowId owner, bool favoritesOnly, bool anki)
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return;
        }

        var entries = history.Search(string.Empty, favoritesOnly, limit: 0);
        if (entries.Count == 0)
        {
            NoticeHost.Show(favoritesOnly ? "还没有收藏" : "还没有翻译历史", "没有可导出的记录", NoticeTone.Warning);
            return;
        }

        try
        {
            var name = HistoryExport.FileName(favoritesOnly, anki);
            var extension = Path.GetExtension(name);
            var picker = new FileSavePicker(owner)
            {
                SuggestedFileName = Path.GetFileNameWithoutExtension(name),
                DefaultFileExtension = extension,
            };
            picker.FileTypeChoices.Add(anki ? "TSV（Anki 卡片）" : "CSV（表格）", new List<string> { extension });
            var file = await picker.PickSaveFileAsync();
            if (file is null || string.IsNullOrEmpty(file.Path))
            {
                return;
            }

            var rows = entries
                .Select(entry => new HistoryRow(
                    entry.Source, entry.Result, entry.TargetLang, entry.Service, entry.CreatedAt, entry.Favorite))
                .ToList();
            var text = anki ? HistoryExport.AnkiTsv(rows) : HistoryExport.Bom + HistoryExport.Csv(rows);
            await File.WriteAllTextAsync(file.Path, text, new System.Text.UTF8Encoding(false));
            NoticeHost.Show($"已导出 {entries.Count} 条", Path.GetFileName(file.Path), NoticeTone.Normal,
                NoticeActions.Reveal(file.Path));
        }
        catch (Exception ex)
        {
            Infrastructure.Log.Error("translate.history-export-failed", ex);
            NoticeHost.Show("导出失败", ex.Message, NoticeTone.Error);
        }
    }

    /// <summary>「清空历史…」：先确认（收藏的会保留），清完用轻提示说留了几条收藏。</summary>
    public static async Task ConfirmClearAsync(XamlRoot root)
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "清空翻译历史？",
            Content = "收藏的记录会保留",
            PrimaryButtonText = "清空",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        var kept = history.Counts().Favorites;
        history.ClearNonFavorites();
        NoticeHost.Show("已清空翻译历史", kept > 0 ? $"保留了 {kept} 条收藏" : string.Empty, NoticeTone.Normal);
    }
}

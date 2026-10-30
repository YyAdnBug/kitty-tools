// 导入 / 从备份恢复之前要先说的（PLAN-v9 G2 G3，照 mac Settings/SettingsTransfer.swift 的 ImportSheet 和 SettingsBackup.title）：
// - Warnings：会让剪贴板历史留得更少、隐私保护变弱的，各一句（只看 Windows 导出的「设置」，mac 的那一类本来就不导）；
// - Addresses：文件里的翻译服务会把要翻的字发到的自己填的地址（去重，不省略）；
// - BackupTitle：备份清单里一份的名字（「10 月 7 日（昨天）」「导入前 · 10 月 8 日（今天） 15:30」）。
using System.Globalization;
using System.Text.Json;

namespace KittyTools.Core;

public static class ImportReview
{
    public const string DailyPrefix = "Kitty Tools 自动备份 ";

    public const string BeforeImportPrefix = "Kitty Tools 导入前 ";

    public static List<string> Warnings(
        SettingsArchive archive, int retentionDays, bool blockSensitive, IReadOnlyCollection<string> excludedApps)
    {
        var warnings = new List<string>();
        if (!archive.AppliesWindowsSettings || archive.Preferences is not { } preferences)
        {
            return warnings;
        }

        if (preferences.TryGetValue("clipboardRetentionDays", out var days) && days.ValueKind == JsonValueKind.Number &&
            days.TryGetInt32(out var incoming) && incoming > 0 && (retentionDays <= 0 || incoming < retentionDays))
        {
            warnings.Add($"剪贴板的普通历史会改成只留 {incoming} 天，更早的会清掉");
        }

        if (blockSensitive && preferences.TryGetValue("clipboardBlockSensitive", out var sensitive) &&
            sensitive.ValueKind == JsonValueKind.False)
        {
            warnings.Add("会关掉「不记录疑似密钥和银行卡号」");
        }

        if (preferences.TryGetValue("clipboardExcludedApps", out var apps) && apps.ValueKind == JsonValueKind.Array)
        {
            var kept = apps.EnumerateArray()
                .Where(app => app.ValueKind == JsonValueKind.String)
                .Select(app => app.GetString()!)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            var dropped = excludedApps.Count(app => !kept.Contains(app));
            if (dropped > 0)
            {
                warnings.Add($"「不记录这些应用里的复制」会少掉 {dropped} 个应用");
            }
        }

        return warnings;
    }

    public static List<string> Addresses(SettingsArchive archive)
        => archive.TranslateServices?
               .Select(service => service.BaseUrl?.Trim())
               .Where(url => !string.IsNullOrEmpty(url))
               .Select(url => url!)
               .Distinct(StringComparer.OrdinalIgnoreCase)
               .ToList()
           ?? new List<string>();

    /// <summary>备份文件名 → 清单里的名字；认不出的返回 null（不列）。</summary>
    public static string? BackupTitle(string fileName, DateTime now)
    {
        var name = Path.GetFileNameWithoutExtension(fileName);
        if (name.StartsWith(DailyPrefix, StringComparison.Ordinal) &&
            DateTime.TryParseExact(name[DailyPrefix.Length..], "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var day))
        {
            return Day(day, now);
        }

        if (name.StartsWith(BeforeImportPrefix, StringComparison.Ordinal) &&
            DateTime.TryParseExact(name[BeforeImportPrefix.Length..], "yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var at))
        {
            return $"导入前 · {Day(at, now)} {at.ToString("HH':'mm", CultureInfo.InvariantCulture)}";
        }

        return null;
    }

    /// <summary>「10 月 7 日（昨天）」：今天 / 昨天 / N 天前。</summary>
    private static string Day(DateTime day, DateTime now)
    {
        var ago = (now.Date - day.Date).Days;
        var relative = ago switch
        {
            <= 0 => "今天",
            1 => "昨天",
            _ => $"{ago} 天前",
        };
        return $"{day.Month} 月 {day.Day} 日（{relative}）";
    }
}

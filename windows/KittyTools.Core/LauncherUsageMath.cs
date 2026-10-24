// 启动器使用分的衰减（纯函数，配单测）：全局时间常数 14 天，同一查询 3 天；
// 每用一次：分 = 衰减到现在的分 + 1。排序加成 = 1 + 0.5·g/(g+3) + q/(q+2)（最多 ×2.5）。
namespace KittyTools.Core;

public static class LauncherUsageMath
{
    public const double GlobalTimeConstantDays = 14;
    public const double QueryTimeConstantDays = 3;
    public const int GlobalLimit = 1024;
    public const int QueryLimit = 512;

    public static string NormalizeQuery(string query)
        => string.Join(' ', LauncherMatch.Fold(query).Split(' ', StringSplitOptions.RemoveEmptyEntries));

    public static double Decayed(double score, long usedAtMs, long nowMs, double timeConstantDays)
    {
        var elapsedDays = Math.Max(0, nowMs - usedAtMs) / 86_400_000.0;
        return score * Math.Exp(-elapsedDays / timeConstantDays);
    }

    public static double Multiplier(double global, double query)
        => 1 + 0.5 * global / (global + 3) + query / (query + 2);
}

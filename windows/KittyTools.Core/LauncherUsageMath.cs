// 启动器使用分的衰减（纯函数，配单测）：全局时间常数 14 天，同一查询 28 天（PLAN-v18 L6，mac ea0c2813：原来 3 天，一周开一次的
// App 选过也等于没学；对标 Alfred 的 4 周）；每用一次：分 = 衰减到现在的分 + 1。
// 排序加成 = 1 + 0.5·g/(g+3) + q/(q+0.5)（最多 ×2.5；选过一次就压过全局最多的加成）。q 里输入的开头对上的记录按一半算（PrefixWeight）。
namespace KittyTools.Core;

public static class LauncherUsageMath
{
    public const double GlobalTimeConstantDays = 14;
    public const double QueryTimeConstantDays = 28;
    public const int GlobalLimit = 1024;
    public const int QueryLimit = 1024;

    /// <summary>在更长的输入下选过的（这次输入是它的开头）按几成算。</summary>
    public const double PrefixWeight = 0.5;

    public static string NormalizeQuery(string query)
        => string.Join(' ', LauncherMatch.Fold(query).Split(' ', StringSplitOptions.RemoveEmptyEntries));

    public static double Decayed(double score, long usedAtMs, long nowMs, double timeConstantDays)
    {
        var elapsedDays = Math.Max(0, nowMs - usedAtMs) / 86_400_000.0;
        return score * Math.Exp(-elapsedDays / timeConstantDays);
    }

    public static double Multiplier(double global, double query)
        => 1 + 0.5 * global / (global + 3) + query / (query + 0.5);
}

// 录屏压缩的规则（PLAN-v6 第 3 批，配单测）：目标不超过原文件的 60%，码率按 45% 重编；输出「原名 压缩版.mp4」。
namespace KittyTools.Core;

public static class CompressionRules
{
    public const double TargetRatio = 0.6;

    public const double BitrateRatio = 0.45;

    public static bool IsSmallEnough(long originalBytes, long compressedBytes)
        => compressedBytes > 0 && compressedBytes <= originalBytes * TargetRatio;

    public static string OutputPath(string source)
    {
        var directory = Path.GetDirectoryName(source) ?? ".";
        var name = Path.GetFileNameWithoutExtension(source);
        var path = Path.Combine(directory, name + " 压缩版.mp4");
        return File.Exists(path) ? Path.Combine(directory, name + " 压缩版 (2).mp4") : path;
    }
}

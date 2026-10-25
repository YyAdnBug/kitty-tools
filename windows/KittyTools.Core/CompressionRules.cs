// 录屏压缩的规则（第四版第 3 批的简化版，配单测）：目标不超过原文件的 60%；
// 先降 JPEG 质量，再不行就缩到 80% 尺寸（分辨率变了，报告里写明）。输出「原名 压缩版.avi」。
namespace KittyTools.Core;

public static class CompressionRules
{
    public const double TargetRatio = 0.6;

    public const float FirstQuality = 0.5f;

    public const float SecondQuality = 0.35f;

    public const float ThirdQuality = 0.25f;

    public static bool IsSmallEnough(long originalBytes, long compressedBytes)
        => compressedBytes > 0 && compressedBytes <= originalBytes * TargetRatio;

    /// <summary>第一轮用 0.5，不够再 0.35、0.25；还不行才缩尺寸。</summary>
    public static float QualityFor(int attempt) => attempt switch
    {
        <= 0 => FirstQuality,
        1 => SecondQuality,
        _ => ThirdQuality,
    };

    public static string OutputPath(string source)
    {
        var directory = Path.GetDirectoryName(source) ?? ".";
        var name = Path.GetFileNameWithoutExtension(source);
        var path = Path.Combine(directory, name + " 压缩版.avi");
        return File.Exists(path) ? Path.Combine(directory, name + " 压缩版 (2).avi") : path;
    }
}

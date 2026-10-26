// 录屏效果的类型和时序常量（PLAN-v6 第 3 批起只保留数据；画由 WgcEffects 在 GPU 纹理上做）。
namespace KittyTools.Core;

public readonly record struct ClickRing(int X, int Y, bool Right, long DownAt, long UpAt);

public readonly record struct Keycap(string Text, long At);

public static class RecordingOverlay
{
    public const int RingDurationMs = 400;

    public const int KeycapDurationMs = 1500;

    public const int RingMaxRadius = 24;

    public const int KeycapHeight = 34;
}
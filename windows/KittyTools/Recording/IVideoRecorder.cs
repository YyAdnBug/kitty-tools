// 录屏器的统一接口（PLAN-v6 第 1 批）：WGC 主路径和 GDI 退路都实现它，RecordingHost 只认这个。
namespace KittyTools;

internal interface IVideoRecorder : IDisposable
{
    int Frames { get; }

    long ElapsedMs { get; }

    string TemporaryPath { get; }

    string OutputPath { get; }

    string? Stop();
}

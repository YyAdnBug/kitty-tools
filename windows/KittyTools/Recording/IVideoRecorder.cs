// 录屏器的统一接口（PLAN-v6 第 1 批）：WGC 主路径和 GDI 退路都实现它，RecordingHost 只认这个。
namespace KittyTools;

internal interface IVideoRecorder : IDisposable
{
    int Frames { get; }

    long ElapsedMs { get; }

    string TemporaryPath { get; }

    string OutputPath { get; }

    string? Stop();

    /// <summary>
    /// 暂停 / 继续（PLAN-v26 V1）：界面只设这个，录制线程照它停写画面和声音、停掉声音设备；继续后时间戳减掉暂停了多久，
    /// 一个文件写到底。
    /// </summary>
    bool Paused { get; set; }

    /// <summary>录制中的实时备注（麦克风 / 系统声音断了会变），给 HUD 的橙字用。</summary>
    string? LiveNote { get; }
}

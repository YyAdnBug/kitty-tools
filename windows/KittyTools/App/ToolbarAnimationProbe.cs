// 自检档（Debug，或 Release 带 KITTY_PROBE_PROFILE）：`--toolbar-anim-record=<目录>` 用合成的冻结帧开截图遮罩（不抓桌面），
// 依次换工具（矩形 → 文字 → 箭头 → 马赛克）、换两次颜色，同时只录遮罩这一扇窗口（WGC，60 fps），录完退出。
// 给 PLAN-v11 C4「样式托盘换工具时 settle 滑过去、色点 pop」出视频、逐帧看（--video-frames）。遮罩会盖住主屏约 4 秒。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class ToolbarAnimationProbe
{
    public const string ArgumentPrefix = "--toolbar-anim-record=";

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        if (ScreenshotSession.StartSynthetic() is not { } overlay)
        {
            Environment.Exit(2);
            return;
        }

        await Task.Delay(900);
        overlay.ProbeTool(AnnotationKind.Rectangle);
        await Task.Delay(500);
        var video = WgcRecorder.StartWindow(overlay.Handle, 60, directory, false, false, out var error, out _);
        if (video is null)
        {
            Log.Warn($"toolbar-anim.record-failed {error}");
            ScreenshotSession.FinishCurrent();
            Environment.Exit(3);
            return;
        }

        await Task.Delay(400);
        foreach (var kind in new[] { AnnotationKind.Text, AnnotationKind.Arrow, AnnotationKind.Mosaic, AnnotationKind.Rectangle })
        {
            overlay.ProbeTool(kind);
            await Task.Delay(600);
        }

        overlay.ProbeColor(3);
        await Task.Delay(500);
        overlay.ProbeColor(5);
        await Task.Delay(500);
        Log.Info($"toolbar-anim.record video={video.Stop()} reduced={Motion.Reduced}");
        video.Dispose();
        ScreenshotSession.FinishCurrent();
        Environment.Exit(0);
    }
}

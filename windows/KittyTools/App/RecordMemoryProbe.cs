// 自检档（Debug，或 Release 带 KITTY_PROBE_PROFILE）：`--record-memory-probe=<次数>` 查「录屏后内存不回落」（PLAN-v11 第 7 批）。
// 开一扇自己的纯色小窗口，连着录 N 次（每次 5 秒、30 fps、不录声音），每次停下后等 20 秒量一次，最后再静置 130 秒量一次。
// 每一行同时记专用工作集（任务管理器那一列）和托管堆，分得清是托管对象留着、还是原生的（D3D / MF / 驱动）留着。
// KITTY_RECMEM_PART=device|pool|encoder 只走到那一步就停（device：只建 D3D 设备；pool：再建帧池和捕获会话、不编码；
// encoder：完整录），用来找是哪一块留下的。只写日志（grep `recmem.`），录下的文件写临时目录、量完删掉。
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class RecordMemoryProbe
{
    public const string ArgumentPrefix = "--record-memory-probe=";

    public static async Task RunAsync(int times)
    {
        var part = Environment.GetEnvironmentVariable("KITTY_RECMEM_PART") ?? "encoder";
        var window = new Microsoft.UI.Xaml.Window
        {
            Title = Paths.ProductName + " 录屏内存探针",
            Content = new Microsoft.UI.Xaml.Controls.Grid
            {
                Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 0x7E, 0x4D, 0xFF)),
            },
        };
        window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(40, 40, 640, 360));
        window.AppWindow.Show(false);
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        await Task.Delay(3000);
        Report($"before part={part}");
        for (var round = 1; round <= times; round++)
        {
            var folder = Path.Combine(Path.GetTempPath(), "kitty-recmem-" + Guid.NewGuid().ToString("N"));
            try
            {
                switch (part)
                {
                    case "device":
                    {
                        using var context = D3DContext.Create(out _);
                        await Task.Delay(5000);
                        break;
                    }

                    case "pool":
                        await CaptureOnlyAsync(handle, 5000);
                        break;
                    default:
                    {
                        var recorder = WgcRecorder.StartWindow(handle, 30, folder, false, false, out var error, out _);
                        if (recorder is null)
                        {
                            Log.Warn($"recmem.start-failed {error}");
                            break;
                        }

                        await Task.Delay(5000);
                        await Task.Run(recorder.Stop);
                        recorder.Dispose();
                        break;
                    }
                }
            }
            finally
            {
                try
                {
                    if (Directory.Exists(folder))
                    {
                        Directory.Delete(folder, recursive: true);
                    }
                }
                catch
                {
                    // 临时目录删不掉无所谓。
                }
            }

            IdleReclaimer.Schedule();
            await Task.Delay(20_000);
            Report($"after-{round}");
            if (Environment.GetEnvironmentVariable("KITTY_RECMEM_GC") == "1")
            {
                // 强制回收一次、跑完终结器：掉下来的那部分是没 Dispose、等终结器才放的 WinRT / COM 包装拿着的。
                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();
                await Task.Delay(3000);
                Report($"after-{round}-gc");
            }
        }

        await Task.Delay(int.TryParse(Environment.GetEnvironmentVariable("KITTY_RECMEM_SETTLE"), out var settle) ? settle * 1000 : 130_000);
        Report("settled");
        window.Close();
        Environment.Exit(0);
    }

    /// <summary>
    /// 自检（KITTY_RECMEM_PART=pool）：只建 D3D 设备、帧池和捕获会话，抓 milliseconds 毫秒（帧来了就放掉），
    /// 不建编码器、不写文件。和完整录比，分得清录完留下的内存在捕获这一半还是编码那一半。
    /// </summary>
    private static async Task CaptureOnlyAsync(IntPtr window, int milliseconds)
    {
        await Task.Run(async () =>
        {
            Windows.Win32.PInvoke.MFStartup(0x00020070, 0);
            try
            {
                using var context = D3DContext.Create(out _);
                if (context is null || WgcInterop.ForWindow(window) is not { } item)
                {
                    return;
                }

                var arrived = 0;
                using var pool = Windows.Graphics.Capture.Direct3D11CaptureFramePool.CreateFreeThreaded(
                    context.WinRt, Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
                pool.FrameArrived += (sender, _) =>
                {
                    using var frame = sender.TryGetNextFrame();
                    arrived++;
                };
                using var session = pool.CreateCaptureSession(item);
                session.StartCapture();
                await Task.Delay(milliseconds);
                Log.Info($"recmem.capture-only arrived={arrived}");
            }
            finally
            {
                Windows.Win32.PInvoke.MFShutdown();
            }
        });
    }

    private static void Report(string step)
    {
        var info = GC.GetGCMemoryInfo();
        Log.Info(
            $"recmem.{step} private={MemoryProbe.PrivateWorkingSetMb():F1}MB managed={GC.GetTotalMemory(false) / 1048576.0:F1}MB " +
            $"heap={info.HeapSizeBytes / 1048576.0:F1}MB committed={info.TotalCommittedBytes / 1048576.0:F1}MB");
    }
}

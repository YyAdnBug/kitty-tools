// 内存探针（第二版 §4.1）：Release AOT 下逐项量「专用工作集」，空闲 wait 秒后读。
// 触发：环境变量 KITTY_MEMORY_PROBE=1（KITTY_MEMORY_PROBE_FAST=1 把 30 s / 120 s 缩成 3 s / 10 s，
// 只用来调试探针本身）。结果一律写日志（grep `memprobe.`），不弹窗、不动用户的数据：
// 5000 条剪贴板用的是临时库，用完删掉。
// 口径同 PLAN §11：GetProcessMemoryInfo 的 PROCESS_MEMORY_COUNTERS_EX2.PrivateWorkingSetSize
// （任务管理器「内存(专用工作集)」）。不许用 EmptyWorkingSet / SetProcessWorkingSetSize 压数字。
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.System.ProcessStatus;

namespace KittyTools;

internal static class MemoryProbe
{
    public static bool Requested => Environment.GetEnvironmentVariable("KITTY_MEMORY_PROBE") == "1";

    private static bool Fast => Environment.GetEnvironmentVariable("KITTY_MEMORY_PROBE_FAST") == "1";

    private static int IdleSeconds => Fast ? 3 : 30;

    private static int SettleSeconds => Fast ? 10 : 120;

    private static string? _probeDirectory;

    public static async void Run()
    {
        if (!Requested)
        {
            return;
        }

        try
        {
            if (Fast)
            {
                IdleReclaimer.DelaySeconds = 5;
            }

            Log.Info($"memprobe.begin fast={Fast} wait={IdleSeconds}s settle={SettleSeconds}s");
            await Task.Delay(IdleSeconds * 1000);
            Report("tray-only");

            ProbeClipboardData();
            await Task.Delay(500);
            Report("clipboard-5000-data");

            OverlayHost.Show(OverlayKind.Clipboard);
            await Task.Delay(1200);
            OverlayHost.Hide(restoreForeground: false);
            await Task.Delay(IdleSeconds * 1000);
            Report("clipboard-panel");

            OverlayHost.Show(OverlayKind.Launcher);
            await Task.Delay(1200);
            OverlayHost.Hide(restoreForeground: false);
            await Task.Delay(IdleSeconds * 1000);
            Report("launcher");

            TranslateHost.ShowInput();
            await Task.Delay(1200);
            TranslateHost.Hide(restoreForeground: false);
            await Task.Delay(IdleSeconds * 1000);
            Report("translate-window");

            ScreenshotSession.Start(ScreenshotMode.Capture);
            await Task.Delay(1500);
            ScreenshotSession.FinishCurrent();
            await Task.Delay(IdleSeconds * 1000);
            Report("screenshot-overlay");

            // R12：第二次截图后的内存（第一次的缓存已经热了，看会不会再涨）。
            ScreenshotSession.Start(ScreenshotMode.Capture);
            await Task.Delay(1500);
            ScreenshotSession.FinishCurrent();
            await Task.Delay(IdleSeconds * 1000);
            Report("screenshot-second");

            // R27：截图之后空闲两分钟（空闲回收会在截图结束两分钟后跑一次），看回没回到截图之前。
            await Task.Delay(SettleSeconds * 1000);
            Report("screenshot-settled");

            await ProbePinAsync();
            await Task.Delay(IdleSeconds * 1000);
            Report("pin-window");

            ShellRuntime.Instance?.ShowSettings(welcome: false);
            await Task.Delay(1500);
            ShellRuntime.Instance?.CloseSettings();
            await Task.Delay(IdleSeconds * 1000);
            Report("settings-window");

            await Task.Delay(SettleSeconds * 1000);
            Report("settled");

            // R27：录屏之后两分钟回到录之前 +5 MB 以内。只录探针自己开的一个小窗口（R16：不录桌面），不录声音。
            // 多等 15 秒：空闲回收也是两分钟，不和读数撞在同一刻。录两次，分清一次性的（编码器、驱动的 DLL）和每次都涨的。
            await ProbeRecordingAsync();
            await Task.Delay((SettleSeconds + 15) * 1000);
            Report("recording-settled");
            await ProbeRecordingAsync();
            await Task.Delay((SettleSeconds + 15) * 1000);
            Report("recording-second-settled");
            Cleanup();
            Log.Info("memprobe.end");
        }
        catch (Exception ex)
        {
            Log.Error("memprobe.failed", ex);
            Cleanup();
        }
    }

    /// <summary>5000 条剪贴板：临时库里一次事务塞满，再让 ClipboardStore.Load 读进内存。</summary>
    private static void ProbeClipboardData()
    {
        try
        {
            _probeDirectory = Path.Combine(Path.GetTempPath(), "kitty-memprobe-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_probeDirectory);
            var database = new Database(Path.Combine(_probeDirectory, "probe.sqlite3"));
            var connection = new SqliteConnection(Path.Combine(_probeDirectory, "probe.sqlite3"));
            connection.Execute("BEGIN IMMEDIATE;");
            using (var statement = connection.Prepare(
                       """
                       INSERT INTO clips(kind, text, copied_at) VALUES ('text', ?1, ?2)
                       """))
            {
                var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                for (var index = 0; index < 5000; index++)
                {
                    statement.Reset();
                    statement.BindText(1, $"memprobe 探针样本 {index}：一段普通的剪贴板文本，用来量 5000 条时占多少内存。");
                    statement.BindInt64(2, now - index * 1000);
                    statement.Step();
                }
            }

            connection.Execute("COMMIT;");
            var store = new ClipboardStore(database, new ImageStore(Path.Combine(_probeDirectory, "images")));
            store.Load();
            Log.Info($"memprobe.clipboard-items count={store.Count}");
            connection.Dispose();
        }
        catch (Exception ex)
        {
            Log.Warn($"memprobe.clipboard-failed {ex.GetType().Name}");
        }
    }

    private static async Task ProbePinAsync()
    {
        try
        {
            // 64 × 64 的不透明小图（PNG 由 ImageCodec 生成）。WinRT 的异步要在后台线程上等。
            var bgra = new byte[64 * 64 * 4];
            for (var index = 0; index < bgra.Length; index += 4)
            {
                bgra[index] = 0x7E;
                bgra[index + 1] = 0x4D;
                bgra[index + 2] = 0xFF;
                bgra[index + 3] = 0xFF;
            }

            var png = await Task.Run(() => ImageCodec.BgraToPngAsync(64, 64, bgra));
            if (png is null)
            {
                Log.Warn("memprobe.pin-no-png");
                return;
            }

            PinHost.Show(png, new PixelBounds(200, 200, 264, 264));
            await Task.Delay(600);
            PinHost.CloseAll();
        }
        catch (Exception ex)
        {
            Log.Warn($"memprobe.pin-failed {ex.GetType().Name}");
        }
    }

    private static async Task ProbeRecordingAsync()
    {
        Microsoft.UI.Xaml.Window? window = null;
        var folder = Path.Combine(Path.GetTempPath(), "kitty-memprobe-record-" + Guid.NewGuid().ToString("N"));
        try
        {
            window = new Microsoft.UI.Xaml.Window
            {
                Title = Paths.ProductName + " 内存探针",
                Content = new Microsoft.UI.Xaml.Controls.Grid
                {
                    Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                        Windows.UI.Color.FromArgb(255, 0x7E, 0x4D, 0xFF)),
                },
            };
            window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(40, 40, 640, 360));
            window.AppWindow.Show(false);
            await Task.Delay(800);
            Report("recording-before");
            var recorder = WgcRecorder.StartWindow(
                WinRT.Interop.WindowNative.GetWindowHandle(window), 30, folder,
                systemAudio: false, microphone: false, out var error, out _);
            if (recorder is null)
            {
                Log.Warn($"memprobe.record-failed {error}");
                return;
            }

            await Task.Delay(5000);
            var path = await Task.Run(recorder.Stop);
            recorder.Dispose();
            Log.Info($"memprobe.recorded bytes={(path is not null && File.Exists(path) ? new FileInfo(path).Length : 0)}");
            IdleReclaimer.Schedule();
        }
        catch (Exception ex)
        {
            Log.Warn($"memprobe.record-failed {ex.GetType().Name}");
        }
        finally
        {
            window?.Close();
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
    }

    private static unsafe void Report(string step)
    {
        var counters = default(PROCESS_MEMORY_COUNTERS_EX2);
        counters.cb = (uint)sizeof(PROCESS_MEMORY_COUNTERS_EX2);
        var ok = PInvoke.GetProcessMemoryInfo(
            PInvoke.GetCurrentProcess(),
            (PROCESS_MEMORY_COUNTERS*)&counters,
            counters.cb);
        var privateMb = ok ? counters.PrivateWorkingSetSize / 1_048_576.0 : -1;
        var workingMb = ok ? counters.WorkingSetSize / 1_048_576.0 : -1;
        var heapMb = GC.GetTotalMemory(forceFullCollection: false) / 1_048_576.0;
        var gc = GC.GetGCMemoryInfo();
        Log.Info(
            $"memprobe.{step} private={privateMb:F1}MB working={workingMb:F1}MB " +
            $"managed={heapMb:F1}MB committed={gc.TotalCommittedBytes / 1_048_576.0:F1}MB " +
            $"fragmented={gc.FragmentedBytes / 1_048_576.0:F1}MB gen2={GC.CollectionCount(2)}");
    }

    private static void Cleanup()
    {
        try
        {
            PinHost.CloseAll();
            if (_probeDirectory is not null && Directory.Exists(_probeDirectory))
            {
                Directory.Delete(_probeDirectory, recursive: true);
            }
        }
        catch
        {
            // 临时目录删不掉无所谓。
        }
    }
}


// 设置 › 录制「录哪个麦克风」的设备列表（PLAN-v11 F12）：WinRT 的 DeviceInformation 列出启用着的录音设备，
// Id 换成 WASAPI 的端点 Id（Core/AudioEndpoints），录屏时 WasaCapture 按它打开。列不出来时只有「跟随系统」。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Devices.Enumeration;

namespace KittyTools;

internal static class AudioDevices
{
    public static async Task<IReadOnlyList<(string Id, string Name)>> MicrophonesAsync()
    {
        var result = new List<(string Id, string Name)>();
        try
        {
            foreach (var device in await DeviceInformation.FindAllAsync(DeviceClass.AudioCapture))
            {
                if (device.IsEnabled && AudioEndpoints.EndpointId(device.Id) is { } id)
                {
                    result.Add((id, device.Name));
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.devices-failed 0x{ex.HResult:X8}");
        }

        return result;
    }

    /// <summary>
    /// 看着录音设备的插拔（PLAN-v26 V3）：列完一遍之后有加、删、启用 / 停用就调 changed（在后台线程）。看不了返回 null（列表就不自动变）。
    /// </summary>
    public static DeviceWatcher? Watch(Action changed)
    {
        try
        {
            var watcher = DeviceInformation.CreateWatcher(DeviceClass.AudioCapture);
            var ready = false;
            watcher.EnumerationCompleted += (_, _) => ready = true;
            watcher.Added += (_, _) =>
            {
                if (ready)
                {
                    changed();
                }
            };
            watcher.Removed += (_, _) => changed();
            watcher.Updated += (_, _) => changed();
            watcher.Start();
            return watcher;
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.devices-watch-failed 0x{ex.HResult:X8}");
            return null;
        }
    }

    public static void StopWatching(DeviceWatcher? watcher)
    {
        if (watcher is null)
        {
            return;
        }

        try
        {
            if (watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted)
            {
                watcher.Stop();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.devices-unwatch-failed 0x{ex.HResult:X8}");
        }
    }
}

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
}

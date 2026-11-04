// 录屏选麦克风（PLAN-v11 F12，mac X18）：设置里用 WinRT 的 DeviceInformation 列设备，录的时候 WASAPI 按端点 Id 打开，
// 两边的 Id 写法不一样——这里把前者换成后者，存进设置的也是后者（重装驱动前一直不变）。
namespace KittyTools.Core;

public static class AudioEndpoints
{
    private const string Marker = "MMDEVAPI#";

    /// <summary>
    /// DeviceInformation.Id（如 <c>\\?\SWD#MMDEVAPI#{0.0.1.00000000}.{guid}#{2eef81be-…}</c>）→ WASAPI 的端点 Id
    /// （<c>{0.0.1.00000000}.{guid}</c>）；认不出这种写法返回 null。
    /// </summary>
    public static string? EndpointId(string? deviceInformationId)
    {
        if (string.IsNullOrEmpty(deviceInformationId))
        {
            return null;
        }

        var start = deviceInformationId.IndexOf(Marker, StringComparison.OrdinalIgnoreCase);
        if (start < 0)
        {
            return null;
        }

        start += Marker.Length;
        var end = deviceInformationId.IndexOf('#', start);
        var id = end < 0 ? deviceInformationId[start..] : deviceInformationId[start..end];
        return id.StartsWith('{') && id.Contains("}.{", StringComparison.Ordinal) && id.EndsWith('}') ? id : null;
    }

    /// <summary>设置里存的设备在不在这次列出来的里面（不在 = 拔了 / 关了，下拉框里写「没连着」，录的时候用系统默认）。</summary>
    public static bool IsPresent(string? saved, IEnumerable<string> present)
        => saved is { Length: > 0 } && present.Contains(saved, StringComparer.OrdinalIgnoreCase);
}

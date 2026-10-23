// 开机启动：HKCU\Software\Microsoft\Windows\CurrentVersion\Run，值是当前 exe 的完整路径（带引号）。
using Microsoft.Win32;

namespace KittyTools.Infrastructure;

internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(Paths.RunValueName) is string value &&
                   string.Equals(value.Trim('"'), Paths.ExecutablePath, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex)
        {
            Log.Error("autostart.read-failed", ex);
            return false;
        }
    }

    public static bool Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (key is null)
            {
                return false;
            }

            if (enabled)
            {
                key.SetValue(Paths.RunValueName, $"\"{Paths.ExecutablePath}\"", RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(Paths.RunValueName, throwOnMissingValue: false);
            }

            return true;
        }
        catch (Exception ex)
        {
            Log.Error("autostart.write-failed", ex);
            return false;
        }
    }
}

// 系统提示音（没有可做的事时响一声，同 mac NSSound.beep）。
namespace KittyTools;

internal static partial class SystemSound
{
    public static void Beep() => MessageBeep(0xFFFFFFFF);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool MessageBeep(uint type);
}

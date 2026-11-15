// 这一刻会话锁没锁（REVIEW R79 / PLAN-v20 M3，mac 状态屏的兜底轮询）：WTSQuerySessionInformation(WTSSessionInfoEx) 读本会话的 SessionFlags。
// 收不到锁屏 / 解锁的通知时（HiddenWindow.SessionNotices 是 false）状态屏每 2 秒问一次，不然「锁屏再解锁就结束」这条出路失效。
// 读不出来给 null（照旧等通知）。WTSINFOEXW：Level（4 字节）之后是联合体（按 8 对齐），Level1 里 SessionId、SessionState、SessionFlags
// 各 4 字节，SessionFlags 在第 16 字节；WTS_SESSIONSTATE_LOCK = 0、UNLOCK = 1（Windows 7 上这两个值是反的，本 App 只支持 10 / 11）。
using System.Runtime.InteropServices;

namespace KittyTools;

internal static partial class SessionLock
{
    private const int WtsSessionInfoEx = 25;
    private const int SessionFlagsOffset = 16;

    /// <summary>true = 锁着，false = 没锁，null = 读不出来。</summary>
    public static unsafe bool? IsLocked()
    {
        IntPtr buffer = IntPtr.Zero;
        try
        {
            if (!WTSQuerySessionInformationW(IntPtr.Zero, unchecked((uint)-1), WtsSessionInfoEx, out buffer, out var bytes) ||
                buffer == IntPtr.Zero || bytes < SessionFlagsOffset + 4 || *(uint*)buffer != 1)
            {
                return null;
            }

            return *(int*)((byte*)buffer + SessionFlagsOffset) switch
            {
                0 => true,
                1 => false,
                _ => null,
            };
        }
        finally
        {
            if (buffer != IntPtr.Zero)
            {
                WTSFreeMemory(buffer);
            }
        }
    }

    [LibraryImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WTSQuerySessionInformationW(IntPtr server, uint session, int infoClass, out IntPtr buffer, out uint bytes);

    [LibraryImport("wtsapi32.dll")]
    private static partial void WTSFreeMemory(IntPtr memory);
}

// 装了 Everything 并且它在运行时，启动器的文件搜索改用它（PLAN-v25 F11、F12、§5 第 3 批）。
// 不带 Everything SDK 的 DLL，照它公开的窗口消息协议自己发（拼包 / 解包在 Core 的 EverythingIpc，配单测）：
// 1. FindWindow 找它的窗口（1.4：EVERYTHING_TASKBAR_NOTIFICATION；1.5 alpha 的实例 1.5a：后面多 _(1.5a)）；
// 2. WM_USER + 401 问数据库载完没有（没载完时查询看起来就是零条，这时候不用它）；
// 3. WM_COPYDATA（dwData 18 = QUERY2W）发查询，回包的窗口是现成的 HiddenWindow（UI 线程本来就在转消息）；
// 4. Everything 往 HiddenWindow 发 WM_COPYDATA 回包：OnCopyData 只认正在等的那一次（dwData = 这次的编号、发送窗口属于 Everything 那个进程），
//    把字节拷出来交给等着的任务；解包在线程池里。
// 任何一步不成（没装、没运行、没载完、1.5 秒没回包、回包坏了）都返回 null，调用方退回 Windows 搜索的索引。
// 日志只记步骤名和错误码，不记查询词、不记路径。
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static unsafe partial class EverythingSearch
{
    public const int WmCopyData = 0x004A;
    private const int WmUser = 0x0400;
    private const int IpcGetMajorVersion = 0;
    private const int IpcGetMinorVersion = 1;
    private const int IpcGetRevision = 2;
    private const int IpcGetBuildNumber = 3;
    private const int IpcIsDbLoaded = 401;
    private const uint SmtoAbortIfHung = 0x0002;
    private const int MaxReplyBytes = 8 << 20;

    private static readonly string[] ClassNames = { "EVERYTHING_TASKBAR_NOTIFICATION", "EVERYTHING_TASKBAR_NOTIFICATION_(1.5a)" };
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromMilliseconds(1500);

    /// <summary>正在等的那一次（同一时间只等一次：新的查询来了，旧的直接作废）。</summary>
    private sealed class Pending
    {
        public required uint Id { get; init; }

        public required uint ProcessId { get; init; }

        public required IntPtr Window { get; init; }

        public TaskCompletionSource<byte[]?> Reply { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private static Pending? _pending;

    /// <summary>正在运行的 Everything 的版本（「1.4.1.1026」）；没找到、或者它还没载完数据库时是 null。设置页和自检用。</summary>
    public static string? RunningVersion()
    {
        var window = Find();
        if (window == IntPtr.Zero || Ask(window, IpcIsDbLoaded) != 1)
        {
            return null;
        }

        return $"{Ask(window, IpcGetMajorVersion)}.{Ask(window, IpcGetMinorVersion)}.{Ask(window, IpcGetRevision)}.{Ask(window, IpcGetBuildNumber)}";
    }

    /// <summary>搜一次；用不了时返回 null（调用方退回索引）。线程池里调。</summary>
    public static async Task<List<EverythingHit>?> SearchAsync(IReadOnlyList<string> tokens, CancellationToken cancellationToken)
    {
        var reply = (IntPtr)HiddenWindow.Hwnd.Value;
        var window = Find();
        if (window == IntPtr.Zero || reply == IntPtr.Zero)
        {
            return null;
        }

        if (Ask(window, IpcIsDbLoaded) != 1)
        {
            Log.Info("everything.not-loaded");
            return null;
        }

        GetWindowThreadProcessId(window, out var processId);
        var pending = new Pending { Id = NewId(), ProcessId = processId, Window = window };
        Interlocked.Exchange(ref _pending, pending)?.Reply.TrySetResult(null);
        try
        {
            var query = EverythingIpc.Query(EverythingIpc.SearchText(tokens), (uint)reply, pending.Id);
            fixed (byte* data = query)
            {
                var copy = new CopyData { Data = EverythingIpc.CopyDataQuery2W, Size = (uint)query.Length, Pointer = data };
                if (SendMessageTimeoutW(window, WmCopyData, reply, (IntPtr)(&copy), SmtoAbortIfHung, 1000, out var accepted) == IntPtr.Zero ||
                    accepted == IntPtr.Zero)
                {
                    Log.Warn($"everything.send-failed {Marshal.GetLastPInvokeError()}");
                    return null;
                }
            }

            byte[]? bytes;
            try
            {
                bytes = await pending.Reply.Task.WaitAsync(ReplyTimeout, cancellationToken);
            }
            catch (TimeoutException)
            {
                Log.Warn("everything.reply-timeout");
                return null;
            }

            if (bytes is null)
            {
                return null; // 被新的查询顶掉了，或者回包太大
            }

            var hits = EverythingIpc.Parse(bytes);
            if (hits is null)
            {
                Log.Warn($"everything.reply-bad bytes={bytes.Length}");
            }

            return hits;
        }
        finally
        {
            Interlocked.CompareExchange(ref _pending, null, pending);
        }
    }

    /// <summary>
    /// HiddenWindow 的窗口过程收到 WM_COPYDATA 时调（UI 线程）。是正在等的那次回包就拷出来、返回 true；别的一律 false、不碰数据。
    /// lParam 指着的数据只在这次调用里有效。
    /// </summary>
    public static bool OnCopyData(nuint wParam, nint lParam)
    {
        var pending = Volatile.Read(ref _pending);
        if (pending is null || lParam == 0)
        {
            return false;
        }

        var copy = (CopyData*)lParam;
        if (copy->Data != pending.Id)
        {
            return false;
        }

        // 发送窗口要属于刚才查的那个 Everything 进程（别的程序猜中编号的话，也不收它的「结果」）
        GetWindowThreadProcessId((IntPtr)wParam, out var sender);
        if ((IntPtr)wParam != pending.Window && sender != pending.ProcessId)
        {
            Log.Warn("everything.reply-sender");
            return false;
        }

        if (copy->Pointer is null || copy->Size > MaxReplyBytes)
        {
            pending.Reply.TrySetResult(null);
            return true;
        }

        pending.Reply.TrySetResult(new ReadOnlySpan<byte>(copy->Pointer, (int)copy->Size).ToArray());
        return true;
    }

    private static IntPtr Find()
    {
        foreach (var name in ClassNames)
        {
            var window = FindWindowW(name, null);
            if (window != IntPtr.Zero)
            {
                return window;
            }
        }

        return IntPtr.Zero;
    }

    /// <summary>WM_USER + 命令（它挂了时 200 ms 放弃，返回 -1）。</summary>
    private static long Ask(IntPtr window, int command)
        => SendMessageTimeoutW(window, WmUser, command, IntPtr.Zero, SmtoAbortIfHung, 200, out var result) == IntPtr.Zero ? -1 : (long)result;

    /// <summary>回包的编号：随机的（别的程序不好猜），避开 0。</summary>
    private static uint NewId()
    {
        Span<byte> bytes = stackalloc byte[4];
        RandomNumberGenerator.Fill(bytes);
        return MemoryMarshal.Read<uint>(bytes) | 1;
    }

    /// <summary>COPYDATASTRUCT：ULONG_PTR dwData、DWORD cbData、PVOID lpData（x64 上 cbData 后面有 4 字节对齐）。</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct CopyData
    {
        public nuint Data;
        public uint Size;
        public byte* Pointer;
    }

    [LibraryImport("user32.dll", EntryPoint = "FindWindowW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr FindWindowW(string className, string? windowName);

    [LibraryImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
    private static partial IntPtr SendMessageTimeoutW(IntPtr window, int message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    private static partial uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}

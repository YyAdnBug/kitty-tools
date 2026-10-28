// 读剪贴板：隐私标记 → 来源 → 内容（文件 → 文本 + 格式 → 图片）。
// 一次更新只开一次剪贴板：隐私标记和内容在同一次打开里读完（第二版 §2 P3）。
// 只读要用的那几种格式（读格式可能触发对方的延迟渲染）。OpenClipboard 失败时隔 30 ms 重试，最多 5 次。
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed record ClipboardRead(
    ClipKind Kind,
    string? Text,
    string? FilePaths,
    string? Html,
    string? Rtf,
    byte[]? ImageData,
    bool ImageIsPng);

/// <summary>一次剪贴板更新的全部信息：隐私标记（是的话不带内容）+ 内容。</summary>
internal sealed record ClipboardCapture(bool IsPrivate, ClipboardRead? Content);

/// <summary>划词取词的 Ctrl+C 兜底：只备份这几样常用格式，还原时再写回去。</summary>
internal sealed record ClipboardSnapshot(
    string? Text,
    string? Html,
    string? Rtf,
    byte[]? Png,
    byte[]? Dib,
    IReadOnlyList<string> Files);

internal static unsafe partial class ClipboardFormats
{
    public const uint CF_DIB = 8;
    public const uint CF_UNICODETEXT = 13;
    public const uint CF_HDROP = 15;
    public const uint CF_DIBV5 = 17;

    /// <summary>超过的文本不记录（防内存暴涨，同 mac 的 5 MB）。</summary>
    public const int MaxTextBytes = 5 * 1_048_576;

    /// <summary>带格式数据超过就只留纯文本。</summary>
    public const int MaxRichBytes = 2 * 1_048_576;

    /// <summary>图片最多读这么多字节（8K 的 32 位 DIB 约 132 MB，再大就只按 PNG 记）。</summary>
    public const int MaxImageBytes = 128 * 1_048_576;

    private const int MaxOpenAttempts = 5;
    private const int OpenRetryDelayMs = 30;

    public static readonly uint HtmlFormat = Register("HTML Format");
    public static readonly uint RtfFormat = Register("Rich Text Format");
    public static readonly uint PngFormat = Register("PNG");
    public static readonly uint PreferredDropEffectFormat = Register("Preferred DropEffect");
    public static readonly uint ExcludeFromMonitorFormat = Register("ExcludeClipboardContentFromMonitorProcessing");
    public static readonly uint ClipboardViewerIgnoreFormat = Register("Clipboard Viewer Ignore");
    public static readonly uint CanIncludeInHistoryFormat = Register("CanIncludeInClipboardHistory");

    /// <summary>密码管理器等打的「不要记录」标记。</summary>
    public static bool IsPrivate()
    {
        if (!OpenClipboard())
        {
            return false;
        }

        try
        {
            return IsPrivateCore();
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>
    /// 一次更新只开一次剪贴板：先看隐私标记，不是隐私的就把内容读出来。
    /// 打开失败返回 null（调用方当这次更新没发生）。
    /// </summary>
    public static ClipboardCapture? Capture()
    {
        if (!OpenClipboard())
        {
            Log.Warn("clipboard.read-open-failed");
            return null;
        }

        try
        {
            if (IsPrivateCore())
            {
                return new ClipboardCapture(true, null);
            }

            return new ClipboardCapture(false, ReadCore());
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    private static bool IsPrivateCore()
    {
        if (Has(ExcludeFromMonitorFormat) || Has(ClipboardViewerIgnoreFormat))
        {
            return true;
        }

        return Has(CanIncludeInHistoryFormat) && ReadDword(CanIncludeInHistoryFormat) == 0;
    }

    /// <summary>备份常用格式（划词时 Ctrl+C 会覆盖剪贴板）。</summary>
    public static ClipboardSnapshot? CaptureSnapshot()
    {
        if (!OpenClipboard())
        {
            return null;
        }

        try
        {
            var text = Has(CF_UNICODETEXT) ? ReadText() : null;
            var html = Has(HtmlFormat) ? ReadRich(HtmlFormat) : null;
            var rtf = Has(RtfFormat) ? ReadRich(RtfFormat) : null;
            var png = PngFormat != 0 && Has(PngFormat) ? ReadBlobWithin(PngFormat, MaxImageBytes) : null;
            var dib = Has(CF_DIBV5) ? ReadBlobWithin(CF_DIBV5, MaxImageBytes)
                : Has(CF_DIB) ? ReadBlobWithin(CF_DIB, MaxImageBytes)
                : null;
            var files = Has(CF_HDROP) ? ReadFiles() : new List<string>();
            return new ClipboardSnapshot(text, html, rtf, png, dib, files);
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>把备份写回去；同时打上「不要进系统剪贴板历史」的标记，免得 Win+V 里多一份。</summary>
    public static bool RestoreSnapshot(ClipboardSnapshot snapshot)
    {
        if (!OpenClipboard())
        {
            return false;
        }

        try
        {
            if (!PInvoke.EmptyClipboard())
            {
                return false;
            }

            if (snapshot.Text is { } text)
            {
                SetBytes(CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0"));
            }

            if (snapshot.Html is { } html)
            {
                SetBytes(HtmlFormat, Encoding.UTF8.GetBytes(html));
            }

            if (snapshot.Rtf is { } rtf)
            {
                SetBytes(RtfFormat, Encoding.ASCII.GetBytes(rtf));
            }

            if (snapshot.Png is { } png)
            {
                SetBytes(PngFormat, png);
            }

            if (snapshot.Dib is { } dib)
            {
                SetBytes(CF_DIBV5, dib);
            }

            if (snapshot.Files.Count > 0)
            {
                SetBytes(CF_HDROP, BuildDropFiles(snapshot.Files));
            }

            if (CanIncludeInHistoryFormat != 0)
            {
                var marker = new byte[4];
                SetBytes(CanIncludeInHistoryFormat, marker);
            }

            return true;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>读一次剪贴板内容；没有可记录的内容（空文本、读不到图片等）返回 null。</summary>
    public static ClipboardRead? Read()
    {
        if (!OpenClipboard())
        {
            Log.Warn("clipboard.read-open-failed");
            return null;
        }

        try
        {
            return ReadCore();
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>调用方已经打开着剪贴板。</summary>
    private static ClipboardRead? ReadCore()
    {
        if (Has(CF_HDROP))
        {
            var paths = ReadFiles();
            if (paths.Count > 0)
            {
                return new ClipboardRead(ClipKind.Files, null, string.Join('\n', paths), null, null, null, false);
            }
        }

        if (Has(CF_UNICODETEXT))
        {
            var text = ReadText();
            if (!string.IsNullOrEmpty(text) && !string.IsNullOrWhiteSpace(text) &&
                Encoding.UTF8.GetByteCount(text) <= MaxTextBytes)
            {
                // PLAN §6.1：HTML 和 RTF 两样都存（以前有 HTML 就不读 RTF）。
                var html = ReadRich(HtmlFormat);
                var rtf = ReadRich(RtfFormat);
                return new ClipboardRead(ClipKind.Text, text, null, html, rtf, null, false);
            }
        }

        if (PngFormat != 0 && Has(PngFormat))
        {
            var png = ReadBlobWithin(PngFormat, MaxImageBytes);
            if (png is { Length: > 0 })
            {
                return new ClipboardRead(ClipKind.Image, null, null, null, null, png, true);
            }
        }

        if (Has(CF_DIBV5) || Has(CF_DIB))
        {
            var dib = ReadBlobWithin(Has(CF_DIBV5) ? CF_DIBV5 : CF_DIB, MaxImageBytes);
            if (dib is { Length: > 0 })
            {
                return new ClipboardRead(ClipKind.Image, null, null, null, null, dib, false);
            }
        }

        return null;
    }

    /// <summary>剪贴板写入方（拿不到时用当时的前台窗口，标成推测值）。本 App 自己的窗口返回 null。</summary>
    public static (string? Exe, string? Name, uint Pid) Source()
    {
        var owner = PInvoke.GetClipboardOwner();
        var hwnd = owner;
        if (hwnd == default)
        {
            hwnd = Foreground.Get();
        }

        if (hwnd == default)
        {
            return (null, null, 0);
        }

        PInvoke.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == (uint)Environment.ProcessId)
        {
            return (null, null, pid);
        }

        // REVIEW R6：从 WebView2 之类的子进程复制时，往上找到主程序。
        var resolved = ProcessTree.Resolve(pid, SnapshotProcesses());
        var processId = resolved != 0 ? resolved : pid;
        var path = ProcessImage(processId);
        if (path is null)
        {
            return (null, null, processId);
        }

        return (path, DisplayName(path), processId);
    }

    /// <summary>进程号 → （父进程号, 文件名）：用 Toolhelp 快照一次拿全，找主程序时只查表（启动器的 kill / port 也用）。</summary>
    internal static Dictionary<uint, (uint Parent, string Name)> SnapshotProcesses()
    {
        var map = new Dictionary<uint, (uint, string)>();
        var snapshot = CreateToolhelp32Snapshot(Th32CsSnapProcess, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1))
        {
            return map;
        }

        try
        {
            var entry = new ProcessEntry32W
            {
                dwSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<ProcessEntry32W>(),
            };
            if (!Process32FirstW(snapshot, ref entry))
            {
                return map;
            }

            do
            {
                var name = (entry.szExeFile ?? string.Empty).TrimEnd('\0');
                map[entry.th32ProcessID] = (entry.th32ParentProcessID, name);
            }
            while (Process32NextW(snapshot, ref entry));
        }
        catch (Exception ex)
        {
            Log.Warn($"clipboard.process-snapshot-failed {ex.GetType().Name}");
        }
        finally
        {
            CloseHandle(snapshot);
        }

        return map;
    }

    private const uint Th32CsSnapProcess = 0x00000002;

    [System.Runtime.InteropServices.StructLayout(
        System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct ProcessEntry32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;

        [System.Runtime.InteropServices.MarshalAs(
            System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [System.Runtime.InteropServices.DllImport(
        "kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry32W entry);

    [System.Runtime.InteropServices.DllImport(
        "kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry32W entry);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string? ProcessImage(uint pid)
    {
        if (pid == 0)
        {
            return null;
        }

        var process = PInvoke.OpenProcess(
            Windows.Win32.System.Threading.PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            pid);
        if (process == default)
        {
            return null;
        }

        try
        {
            Span<char> buffer = stackalloc char[1024];
            uint size = (uint)buffer.Length;
            fixed (char* p = buffer)
            {
                if (!PInvoke.QueryFullProcessImageName(process, 0, new PWSTR(p), &size))
                {
                    return null;
                }
            }

            return new string(buffer[..(int)size]);
        }
        finally
        {
            PInvoke.CloseHandle(process);
        }
    }

    public static string DisplayName(string exePath)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(exePath);
            if (!string.IsNullOrWhiteSpace(info.FileDescription))
            {
                return info.FileDescription;
            }
        }
        catch
        {
            // 取不到版本信息就用文件名。
        }

        return Path.GetFileNameWithoutExtension(exePath);
    }

    public static bool OpenClipboard()
    {
        for (var attempt = 0; attempt < MaxOpenAttempts; attempt++)
        {
            if (PInvoke.OpenClipboard(HiddenWindow.Hwnd))
            {
                return true;
            }

            Thread.Sleep(OpenRetryDelayMs);
        }

        return false;
    }

    private static bool Has(uint format) => format != 0 && PInvoke.IsClipboardFormatAvailable(format);

    private static void* Lock(uint format, out nuint size, out IntPtr local)
    {
        size = 0;
        local = IntPtr.Zero;
        var handle = PInvoke.GetClipboardData(format);
        if (handle == default)
        {
            return null;
        }

        local = (IntPtr)handle.Value;
        size = GlobalSize(local);
        return (void*)GlobalLock(local);
    }

    private static string? ReadText()
    {
        var pointer = Lock(CF_UNICODETEXT, out var size, out var local);
        if (pointer is null)
        {
            return null;
        }

        try
        {
            var chars = size == 0 ? 0 : (int)(size / sizeof(char));
            if (chars == 0)
            {
                return Marshal.PtrToStringUni((IntPtr)pointer);
            }

            var span = new ReadOnlySpan<char>(pointer, chars);
            var end = span.IndexOf('\0');
            if (end >= 0)
            {
                span = span[..end];
            }

            return new string(span);
        }
        finally
        {
            GlobalUnlock(local);
        }
    }

    private static string? ReadRich(uint format)
    {
        // REVIEW R59：以前用 ReadBlob 带上限读，超长会被截断成一半再存下来——粘贴回 Word / Outlook
        // 是坏的，划词兜底时还原的也是截断版（等于把用户原来的富文本弄坏）。改成超了就整块不要，
        // 和图片那几处一样：只留纯文本。
        var bytes = ReadBlobWithin(format, MaxRichBytes);
        if (bytes is not { Length: > 0 })
        {
            return null;
        }

        try
        {
            return Encoding.UTF8.GetString(bytes);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>超过上限就当读不到：图片截一半写回去会坏，不能截断。</summary>
    private static byte[]? ReadBlobWithin(uint format, int maximum)
    {
        var pointer = Lock(format, out var size, out var local);
        if (pointer is null || size == 0)
        {
            return null;
        }

        try
        {
            if (size > (nuint)maximum)
            {
                Log.Warn($"clipboard.read-too-large format={format} bytes={size}");
                return null;
            }

            var bytes = new byte[(int)size];
            new ReadOnlySpan<byte>(pointer, bytes.Length).CopyTo(bytes);
            return bytes;
        }
        finally
        {
            GlobalUnlock(local);
        }
    }

    private static uint ReadDword(uint format)
    {
        var pointer = Lock(format, out var size, out var local);
        if (pointer is null || size < sizeof(uint))
        {
            return 0;
        }

        try
        {
            return *(uint*)pointer;
        }
        finally
        {
            GlobalUnlock(local);
        }
    }

    /// <summary>CF_HDROP：DROPFILES 头 + 双 \0 结尾的文件名表（宽字符或 ANSI）。</summary>
    private static List<string> ReadFiles()
    {
        var pointer = Lock(CF_HDROP, out var size, out var local);
        if (pointer is null || size < 20)
        {
            return new List<string>();
        }

        try
        {
            var bytes = new ReadOnlySpan<byte>(pointer, (int)size);
            var offset = BitConverter.ToInt32(bytes);
            var wide = BitConverter.ToInt32(bytes[16..]) != 0;
            if (offset < 0 || offset >= bytes.Length)
            {
                return new List<string>();
            }

            var list = new List<string>();
            var cursor = offset;
            if (wide)
            {
                while (cursor + sizeof(char) <= bytes.Length)
                {
                    var chars = MemoryMarshal.Cast<byte, char>(bytes[cursor..]);
                    var end = chars.IndexOf('\0');
                    if (end <= 0)
                    {
                        break;
                    }

                    list.Add(new string(chars[..end]));
                    cursor += (end + 1) * sizeof(char);
                }
            }
            else
            {
                while (cursor < bytes.Length && bytes[cursor] != 0)
                {
                    var end = bytes[cursor..].IndexOf((byte)0);
                    if (end <= 0)
                    {
                        break;
                    }

                    list.Add(Encoding.Default.GetString(bytes.Slice(cursor, end)));
                    cursor += end + 1;
                }
            }

            return list;
        }
        finally
        {
            GlobalUnlock(local);
        }
    }

    private static uint Register(string name)
    {
        fixed (char* p = name)
        {
            return PInvoke.RegisterClipboardFormat(new PCWSTR(p));
        }
    }

    private static bool SetBytes(uint format, byte[] bytes)
    {
        var memory = PInvoke.GlobalAlloc(Windows.Win32.System.Memory.GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE, (nuint)bytes.Length);
        if (memory == default)
        {
            return false;
        }

        var destination = PInvoke.GlobalLock(memory);
        if (destination is null)
        {
            PInvoke.GlobalFree(memory);
            return false;
        }

        bytes.AsSpan().CopyTo(new Span<byte>(destination, bytes.Length));
        PInvoke.GlobalUnlock(memory);
        if (PInvoke.SetClipboardData(format, new HANDLE(memory.Value)) == default)
        {
            PInvoke.GlobalFree(memory);
            return false;
        }

        return true;
    }

    private static byte[] BuildDropFiles(IReadOnlyList<string> paths)
    {
        var names = paths.Select(path => path.Replace('/', '\\')).ToList();
        var chars = names.Sum(name => name.Length + 1) + 1;
        const int header = 20;
        var bytes = new byte[header + chars * sizeof(char)];
        BitConverter.TryWriteBytes(bytes.AsSpan(0), header);
        BitConverter.TryWriteBytes(bytes.AsSpan(16), 1); // fWide
        var cursor = header;
        foreach (var name in names)
        {
            var encoded = Encoding.Unicode.GetBytes(name);
            encoded.CopyTo(bytes, cursor);
            cursor += encoded.Length + sizeof(char);
        }

        return bytes;
    }

    // 剪贴板数据是 HGLOBAL：CsWin32 生成的 GlobalLock / GlobalSize 重载要 SafeHandle，这里自己声明。
    [LibraryImport("kernel32.dll", EntryPoint = "GlobalLock", SetLastError = true)]
    private static partial IntPtr GlobalLock(IntPtr handle);

    [LibraryImport("kernel32.dll", EntryPoint = "GlobalUnlock", SetLastError = true)]
    private static partial int GlobalUnlock(IntPtr handle);

    [LibraryImport("kernel32.dll", EntryPoint = "GlobalSize", SetLastError = true)]
    private static partial nuint GlobalSize(IntPtr handle);
}

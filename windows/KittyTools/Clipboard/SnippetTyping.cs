// 打关键词展开片段（PLAN-v26 C5，照 mac 0.10.3 SnippetExpand；设置 › 剪贴板「打关键词展开片段」，默认开）：在任何程序里打出某条片段的关键词，
// 就换成那条片段（{cursor}、{input} 照样能用）。Windows 的做法：
// - 听键盘复用连按修饰键那一份 Raw Input（ModifierTapListener.RawKey：只听不拦，不装低级键盘钩子），**只在开关开着、剪贴板功能开着、
//   至少一条片段有关键词时才注册**——没设关键词的人零开销（日志 snippet-typing.listening=False）。
// - 虚拟键按前台线程的键盘布局（ToUnicodeEx，不改系统的死键状态）换成字，只在内存里记最近几个字（Core SnippetKeyBuffer），
//   不存盘、不进日志；换了前台窗口就清空。前台输入法在中文模式（打的是拼音）时不记。自己 SendInput 发的键 hDevice 是 0，Raw Input 那边已经滤掉。
// - 认出来：不展开的——排除的应用（剪贴板「不记录」那几个）、焦点是密码框（UIA IsPassword）、提权的窗口（UIPI，发不过去，什么都不做）、
//   我们自己的窗口（便签里的展开没做，ponytail）；展开：SendInput 退格删掉关键词 → 写剪贴板、Ctrl+V → {cursor} 往左挪 → 还原原来的剪贴板
//   （不记历史）。带 {input} 的：退格之后打开剪贴板面板、选中这条、在面板里填空再粘（目标还是原来那扇窗口）。
// ponytail: 不听鼠标，点到别处接着打不清空（换窗口才清）；同一扇窗口里换了输入框也不清。要准就加鼠标的 Raw Input 只看按键位。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Accessibility;

namespace KittyTools;

internal static partial class SnippetTyping
{
    private static readonly SnippetKeyBuffer Buffer = new();
    private static HashSet<string> _keywords = new(StringComparer.Ordinal);
    private static HWND _window;
    private static bool _listening;
    private static bool _expanding;

    /// <summary>设置、片段、功能开关变了时重新看要不要听键盘（ShellRuntime 在启动和这几样变化时调）。</summary>
    public static void Refresh()
    {
        var store = ClipboardService.Instance?.Store;
        _keywords = store is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : store.Items.Where(item => item is { Kind: ClipKind.Text, Snippet: true, Keyword: not null }).Select(item => item.Keyword!)
                .ToHashSet(StringComparer.Ordinal);
        var wanted = SettingsService.Current.ClipboardSnippetExpand && Features.IsOn(Feature.Clipboard) && _keywords.Count > 0;
        if (wanted == _listening)
        {
            return;
        }

        _listening = wanted;
        Buffer.Reset();
        if (wanted)
        {
            ModifierTapListener.RawKey += OnKey;
        }
        else
        {
            ModifierTapListener.RawKey -= OnKey;
        }

        ModifierTapListener.SetKeysWanted(wanted);
        Log.Info($"snippet-typing.listening={wanted} keywords={_keywords.Count}");
    }

    private static unsafe void OnKey(uint key, bool up)
    {
        if (up || _expanding)
        {
            return;
        }

        var window = PInvoke.GetForegroundWindow();
        if (window != _window)
        {
            _window = window;
            Buffer.Reset();
        }

        if (window == default || Foreground.IsOurs(window))
        {
            return;
        }

        var thread = PInvoke.GetWindowThreadProcessId(window, null);
        if (ChineseImeMode(window))
        {
            Buffer.Reset();
            return;
        }

        var control = Down(0x11);
        var alt = Down(0x12);
        var win = Down(0x5B) || Down(0x5C);
        var characters = Characters(key, thread);
        if (Buffer.Press(SnippetKeyBuffer.Classify(key, control, alt, win, characters), _keywords) is { } keyword)
        {
            _ = ExpandAsync(keyword, window);
        }
    }

    private static async Task ExpandAsync(string keyword, HWND window)
    {
        if (ClipboardService.Instance?.Store is not { } store ||
            store.Items.FirstOrDefault(item => item is { Kind: ClipKind.Text, Snippet: true } && item.Keyword == keyword) is not { } entry)
        {
            return;
        }

        var pid = Foreground.PidOf(window);
        if (Foreground.IsProcessElevated(pid) && !Foreground.IsProcessElevated((uint)Environment.ProcessId))
        {
            Log.Info("snippet-typing.skip reason=elevated");
            return;
        }

        if (ClipboardService.Instance.IsExcluded(ClipboardFormats.ProcessImage(pid)))
        {
            Log.Info("snippet-typing.skip reason=excluded");
            return;
        }

        if (await Task.Run(FocusIsPassword))
        {
            Log.Info("snippet-typing.skip reason=password");
            return;
        }

        _expanding = true;
        try
        {
            // 修饰键还按着（Shift 打的分号）就等它松开，免得退格变成 Shift+Backspace
            Keyboard.WaitAndReleaseModifiers(300);
            Keyboard.SendBackspaces(keyword.Length);
            if (Expander.InputsOf(entry).Count > 0)
            {
                // 带 {input}：在剪贴板面板里填空再粘（面板记下的目标就是这扇窗口）
                OverlayHost.Show(OverlayKind.Clipboard);
                OverlayHost.VisibleClipboard?.AskInputsFor(entry.Id);
                Log.Info("snippet-typing.expand inputs=True");
                return;
            }

            var expansion = Expander.Of(entry, store, new Dictionary<string, string>());
            if (expansion is not { } expanded)
            {
                return;
            }

            var backup = ClipboardFormats.CaptureSnapshot();
            var pasted = Paster.Paste(window, () => ClipboardWriter.WriteText(expanded.Text), ClipboardService.Instance);
            if (pasted && expanded.CursorBackChars > 0)
            {
                await Task.Delay(80);
                Paster.SendLeft(expanded.CursorBackChars);
            }

            store.Bump(entry.Id);
            // 等目标程序把剪贴板里的读走再还原（同划词取字）；还原的不记历史
            await Task.Delay(400);
            if (backup is not null)
            {
                ClipboardService.Instance.MarkOwnWrite();
                ClipboardFormats.RestoreSnapshot(backup);
                ClipboardService.Instance.MarkOwnWrite();
            }

            Log.Info($"snippet-typing.expand ok={pasted}");
        }
        catch (Exception ex)
        {
            Log.Warn($"snippet-typing.failed {ex.GetType().Name}");
        }
        finally
        {
            _expanding = false;
            Buffer.Reset();
        }
    }

    /// <summary>按前台线程的键盘布局把虚拟键换成字（ToUnicodeEx 第 4 位：不改死键状态）；死键的第一下、换不出来的是空串。</summary>
    private static unsafe string Characters(uint key, uint thread)
    {
        var state = stackalloc byte[256];
        foreach (var vk in new[] { 0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 })
        {
            state[vk] = Down(vk) ? (byte)0x80 : (byte)0;
        }

        state[0x14] = (byte)(GetKeyState(0x14) & 1); // Caps Lock 的开关
        var layout = GetKeyboardLayout(thread);
        var scan = MapVirtualKeyExW(key, 0, layout);
        var buffer = stackalloc char[8];
        var count = ToUnicodeEx(key, scan, state, buffer, 8, 4, layout);
        return count > 0 ? new string(buffer, 0, count) : string.Empty;
    }

    private static bool Down(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    /// <summary>前台的输入法开着、在中文（本地语言）模式：打的是拼音，不记。问不到时当不是。</summary>
    private static unsafe bool ChineseImeMode(HWND window)
    {
        var ime = ImmGetDefaultIMEWnd((IntPtr)window.Value);
        if (ime == IntPtr.Zero)
        {
            return false;
        }

        nuint open = 0;
        nuint mode = 0;
        const uint ImeControl = 0x0283;
        if (SendMessageTimeoutW(ime, ImeControl, 0x5 /* IMC_GETOPENSTATUS */, 0, 0x2 /* SMTO_ABORTIFHUNG */, 50, &open) == 0 || open == 0)
        {
            return false;
        }

        return SendMessageTimeoutW(ime, ImeControl, 0x1 /* IMC_GETCONVERSIONMODE */, 0, 0x2, 50, &mode) != 0 && (mode & 1) != 0;
    }

    /// <summary>焦点是不是密码框（UIA IsPassword）；问不到当不是。在线程池里调。</summary>
    private static unsafe bool FocusIsPassword()
    {
        var initialized = PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED).Succeeded;
        try
        {
            if (CUIAutomation.CreateInstance<IUIAutomation>(out var automation).Failed || automation is null)
            {
                return false;
            }

            try
            {
                var focused = automation->GetFocusedElement();
                if (focused is null)
                {
                    return false;
                }

                try
                {
                    return focused->CurrentIsPassword;
                }
                finally
                {
                    focused->Release();
                }
            }
            finally
            {
                automation->Release();
            }
        }
        catch (Exception)
        {
            return false;
        }
        finally
        {
            if (initialized)
            {
                PInvoke.CoUninitialize();
            }
        }
    }

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int key);

    [LibraryImport("user32.dll")]
    private static partial short GetKeyState(int key);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetKeyboardLayout(uint thread);

    [LibraryImport("user32.dll")]
    private static partial uint MapVirtualKeyExW(uint code, uint mapType, IntPtr layout);

    [LibraryImport("user32.dll")]
    private static unsafe partial int ToUnicodeEx(uint key, uint scan, byte* state, char* buffer, int size, uint flags, IntPtr layout);

    [LibraryImport("imm32.dll")]
    private static partial IntPtr ImmGetDefaultIMEWnd(IntPtr window);

    [LibraryImport("user32.dll")]
    private static unsafe partial IntPtr SendMessageTimeoutW(IntPtr window, uint message, nuint wParam, nint lParam, uint flags, uint timeout, nuint* result);
}

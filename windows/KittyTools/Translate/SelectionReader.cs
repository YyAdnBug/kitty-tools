// 划词取词：先用 UI Automation 读焦点元素的选中文字（MTA 线程，500 ms 超时）；
// 读不到再「备份剪贴板 → 发 Ctrl+C → 等剪贴板序号变化（最多 500 ms）→ 读文本 → 还原」。
// 调用方保证：取到词之前不显示翻译浮窗（先显示会抢走原窗口的焦点，选区就没了）。
// ponytail: UIA 的超时只是不再等结果，卡住的 COM 调用要等它自己返回；第一版接受。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Accessibility;

namespace KittyTools;

internal static class SelectionReader
{
    public static async Task<string?> ReadAsync(CancellationToken cancellationToken)
    {
        var text = await ReadViaUiaAsync(cancellationToken);
        if (!string.IsNullOrWhiteSpace(text))
        {
            Log.Info($"selection.uia chars={text.Trim().Length}");
            return text.Trim();
        }

        var copied = await ReadViaClipboardAsync(cancellationToken);
        Log.Info(copied is null ? "selection.none" : $"selection.clipboard chars={copied.Length}");
        return copied;
    }

    private static async Task<string?> ReadViaUiaAsync(CancellationToken cancellationToken)
    {
        try
        {
            var task = Task.Run(ReadViaUia, cancellationToken);
            var finished = await Task.WhenAny(task, Task.Delay(500, cancellationToken));
            if (finished != task)
            {
                return null;
            }

            return await task;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch
        {
            return null;
        }
    }

    private static unsafe string? ReadViaUia()
    {
        var initialized = false;
        try
        {
            var result = PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED);
            initialized = result.Succeeded;
            if (CUIAutomation.CreateInstance<IUIAutomation>(out var automation).Failed || automation is null)
            {
                return null;
            }

            try
            {
                var focused = automation->GetFocusedElement();
                if (focused is null)
                {
                    return null;
                }

                try
                {
                    var unknown = focused->GetCurrentPattern(UIA_PATTERN_ID.UIA_TextPatternId);
                    if (unknown is null)
                    {
                        return null;
                    }

                    try
                    {
                        if (unknown->QueryInterface(out IUIAutomationTextPattern* pattern).Failed || pattern is null)
                        {
                            return null;
                        }

                        try
                        {
                            var ranges = pattern->GetSelection();
                            if (ranges is null)
                            {
                                return null;
                            }

                            try
                            {
                                if (ranges->Length <= 0)
                                {
                                    return null;
                                }

                                var range = ranges->GetElement(0);
                                if (range is null)
                                {
                                    return null;
                                }

                                try
                                {
                                    var text = range->GetText(2048);
                                    try
                                    {
                                        return text.ToString();
                                    }
                                    finally
                                    {
                                        PInvoke.SysFreeString(text);
                                    }
                                }
                                finally
                                {
                                    range->Release();
                                }
                            }
                            finally
                            {
                                ranges->Release();
                            }
                        }
                        finally
                        {
                            pattern->Release();
                        }
                    }
                    finally
                    {
                        unknown->Release();
                    }
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
        catch
        {
            return null;
        }
        finally
        {
            if (initialized)
            {
                PInvoke.CoUninitialize();
            }
        }
    }

    private static async Task<string?> ReadViaClipboardAsync(CancellationToken cancellationToken)
    {
        var service = ClipboardService.Instance;
        var target = Foreground.Get();
        if (service is null || target == default)
        {
            return null;
        }

        var targetElevated = Foreground.IsProcessElevated(Foreground.PidOf(target));
        var selfElevated = Foreground.IsProcessElevated((uint)Environment.ProcessId);
        if (targetElevated && !selfElevated)
        {
            // SendInput 会被系统悄悄拦掉：不去改用户剪贴板。
            return null;
        }

        service.PauseForSelection();
        var backup = ClipboardFormats.CaptureSnapshot();
        try
        {
            var before = PInvoke.GetClipboardSequenceNumber();
            if (!Keyboard.SendCtrlC())
            {
                return null;
            }

            var deadline = Environment.TickCount64 + 500;
            while (Environment.TickCount64 < deadline)
            {
                if (PInvoke.GetClipboardSequenceNumber() != before)
                {
                    break;
                }

                try
                {
                    await Task.Delay(12, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    return null;
                }
            }

            if (PInvoke.GetClipboardSequenceNumber() == before)
            {
                return null;
            }

            var read = ClipboardFormats.Read();
            var text = read?.Text;
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }
        finally
        {
            if (backup is not null)
            {
                ClipboardFormats.RestoreSnapshot(backup);
            }

            service.ResumeAfterSelection();
        }
    }
}

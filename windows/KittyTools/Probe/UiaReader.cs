// 用 UI Automation 读当前焦点元素里选中的文字（PLAN §7.4 划词的第一步）。
// 在专门的 MTA 线程上做：UIA 客户端不要在 UI 的 STA 线程上调。
// 第 0 批量的是「CsWin32 生成的 COM 在 AOT 下能不能用」和一次调用的耗时。
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Accessibility;

namespace KittyTools;

internal static unsafe class UiaReader
{
    public static (string Text, string Status, double Ms) ReadFocusedSelection(int timeoutMs, string? selectText = null)
    {
        var result = (Text: string.Empty, Status: "not-run", Ms: 0.0);
        var done = new ManualResetEventSlim();
        var thread = new Thread(() =>
        {
            var t0 = Stopwatch.GetTimestamp();
            try
            {
                result = (ReadOnMta(selectText), "ok", 0);
            }
            catch (Exception ex)
            {
                result = (string.Empty, ex.GetType().Name, 0);
            }
            finally
            {
                result.Ms = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
                done.Set();
            }
        })
        {
            IsBackground = true,
            Name = "KittyTools.UIA",
        };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();

        if (!done.Wait(timeoutMs))
        {
            return (string.Empty, "timeout", 0);
        }

        return result;
    }

    private static string ReadOnMta(string? selectText)
    {
        var hr = PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED);
        try
        {
            if (hr.Failed && hr.Value != 1) // S_FALSE = 已经初始化过
            {
                return string.Empty;
            }

            var create = CUIAutomation.CreateInstance<IUIAutomation>(out var automation);
            if (create.Failed || automation == null)
            {
                ProbeLog.Write("uia.create-failed", ("hr", create.Value));
                return string.Empty;
            }

            try
            {
                var element = automation->GetFocusedElement();
                if (element == null)
                {
                    ProbeLog.Write("uia.no-focus");
                    return string.Empty;
                }

                var controlType = element->CurrentControlType;
                var className = element->CurrentClassName;
                ProbeLog.Write(
                    "uia.focus",
                    ("type", controlType.ToString()),
                    ("class", className.Value == null ? string.Empty : new string(className.Value)));

                try
                {
                    var pattern = element->GetCurrentPattern(UIA_PATTERN_ID.UIA_TextPatternId);
                    if (pattern == null)
                    {
                        ProbeLog.Write("uia.no-textpattern");
                        return string.Empty;
                    }

                    try
                    {
                        var textPattern = (IUIAutomationTextPattern*)pattern;

                        // 测试用：先用 UIA 自己把 needle 选中，再读回来。
                        // 正式流程里选中的文字是用户用键盘 / 鼠标选的。
                        if (!string.IsNullOrEmpty(selectText))
                        {
                            SelectByUia(textPattern, selectText);
                        }

                        var ranges = textPattern->GetSelection();
                        if (ranges == null)
                        {
                            return string.Empty;
                        }

                        try
                        {
                            var count = ranges->Length;
                            ProbeLog.Write("uia.ranges", ("count", count));
                            if (count <= 0)
                            {
                                return string.Empty;
                            }

                            var range = ranges->GetElement(0);
                            if (range == null)
                            {
                                return string.Empty;
                            }

                            try
                            {
                                var bstr = range->GetText(-1);
                                ProbeLog.Write("uia.text", ("has_value", bstr.Value != null));
                                var text = bstr.Value == null ? string.Empty : Marshal.PtrToStringBSTR((IntPtr)bstr.Value) ?? string.Empty;
                                if (bstr.Value != null)
                                {
                                    PInvoke.SysFreeString(bstr);
                                }
                                return text;
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
                        ((IUnknown*)pattern)->Release();
                    }
                }
                finally
                {
                    element->Release();
                }
            }
            finally
            {
                automation->Release();
            }
        }
        finally
        {
            if (!hr.Failed)
            {
                PInvoke.CoUninitialize();
            }
        }
    }

    private static void SelectByUia(IUIAutomationTextPattern* textPattern, string needle)
    {
        var document = textPattern->DocumentRange;
        if (document == null)
        {
            return;
        }

        try
        {
            fixed (char* p = needle)
            {
                var found = document->FindText(new BSTR(p), false, false);
                if (found == null)
                {
                    ProbeLog.Write("uia.select-not-found");
                    return;
                }

                try
                {
                    found->Select();
                    ProbeLog.Write("uia.selected-by-uia", ("chars", needle.Length));
                }
                finally
                {
                    found->Release();
                }
            }
        }
        finally
        {
            document->Release();
        }
    }
}

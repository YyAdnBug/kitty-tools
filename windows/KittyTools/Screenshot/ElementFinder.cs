// 截图框选时悬停识别窗口里的元素（PLAN-v20 E1，照 mac Screenshot/ElementFinder.swift；D4：冻结时后台取、悬停只查取到的那份）：
// 指针第一次停进一扇窗口时，在后台线程上用 UI Automation 读这扇窗口里控件视图的元素和它们的框（ElementFromHandle + FindAllBuildCache，
// 只缓存 BoundingRectangle，一次跨进程调用拿回全部）；读完之前、读不出来时照旧只认整扇窗口。
// - ElementFromPoint 会命中自家的框选遮罩，所以按冻结时记下的窗口句柄问（同 mac「只问冻结时那扇窗口的主人」）；
// - 一扇窗口最多问一次（这次框选里）；连接 / 一次调用都设了时限（IUIAutomation2 的 ConnectionTimeout / TransactionTimeout），
//   超时、出错的那扇窗口这次只认整扇；本 App 自己的窗口不问；最多留 MaxElements 个框（再多是网页里的一个个字）。
// - UIA 要 MTA：每次在线程池线程上 CoInitializeEx(MTA)、用完 CoUninitialize。
using System.Collections.Concurrent;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Accessibility;

namespace KittyTools;

internal static class ElementFinder
{
    /// <summary>一扇窗口最多留这么多个框（读回来的元素按出现顺序，外层的先来）。</summary>
    public const int MaxElements = 3000;

    /// <summary>跨进程问一次最多等这么久（毫秒）。</summary>
    public const uint TimeoutMs = 600;

    /// <summary>窗口句柄 → 读到的框（物理像素、屏幕坐标）；null = 读不出 / 超时（只认整扇窗口）。</summary>
    private static readonly ConcurrentDictionary<IntPtr, Task<List<(int Left, int Top, int Right, int Bottom)>?>> Asked = new();

    /// <summary>自检（--element-probe）：自己开的测试窗口也问。</summary>
    public static bool AllowOwnForProbe { get; set; }

    /// <summary>是本 App 自己的窗口（不问）。</summary>
    public static unsafe bool IsOwn(IntPtr hwnd)
    {
        uint process = 0;
        PInvoke.GetWindowThreadProcessId(new HWND((void*)hwnd), &process);
        return process == (uint)Environment.ProcessId;
    }

    /// <summary>新的一次框选：之前问到的全扔掉（窗口里的东西会变）。</summary>
    public static void Reset() => Asked.Clear();

    /// <summary>这扇窗口读好了的框；还在读、没问过的给 null（第一次问会在后台开始读，读完 ready 回调一次，在线程池上）。</summary>
    public static List<(int Left, int Top, int Right, int Bottom)>? Elements(IntPtr hwnd, Action ready)
    {
        var task = Asked.GetOrAdd(hwnd, handle =>
        {
            var started = Task.Run(() => Read(handle));
            started.ContinueWith(_ => ready(), TaskScheduler.Default);
            return started;
        });
        return task.IsCompletedSuccessfully ? task.Result : null;
    }

    /// <summary>读一扇窗口（线程池线程上，同步）：控件视图里的全部后代元素的框。读不出、超时给 null。</summary>
    public static unsafe List<(int Left, int Top, int Right, int Bottom)>? Read(IntPtr hwnd)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var initialized = PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED).Succeeded;
        IUIAutomation* automation = null;
        IUIAutomationElement* root = null;
        IUIAutomationCacheRequest* request = null;
        IUIAutomationCondition* condition = null;
        IUIAutomationElementArray* found = null;
        try
        {
            if (CUIAutomation.CreateInstance<IUIAutomation>(out automation).Failed || automation is null)
            {
                return null;
            }

            if (((IUnknown*)automation)->QueryInterface(out IUIAutomation2* second).Succeeded && second is not null)
            {
                second->ConnectionTimeout = TimeoutMs;
                second->TransactionTimeout = TimeoutMs;
                second->Release();
            }

            root = automation->ElementFromHandle(new HWND((void*)hwnd));
            condition = automation->ControlViewCondition;
            request = automation->CreateCacheRequest();
            if (root is null || condition is null || request is null)
            {
                return null;
            }

            request->AddProperty(UIA_PROPERTY_ID.UIA_BoundingRectanglePropertyId);
            request->TreeFilter = condition;
            found = root->FindAllBuildCache(TreeScope.TreeScope_Descendants, condition, request);
            if (found is null)
            {
                return null;
            }

            var count = Math.Min(found->Length, MaxElements);
            var result = new List<(int, int, int, int)>(count);
            for (var index = 0; index < count; index++)
            {
                var element = found->GetElement(index);
                if (element is null)
                {
                    continue;
                }

                try
                {
                    var rect = element->CachedBoundingRectangle;
                    if (rect.right > rect.left && rect.bottom > rect.top)
                    {
                        result.Add((rect.left, rect.top, rect.right, rect.bottom));
                    }
                }
                finally
                {
                    element->Release();
                }
            }

            Log.Info($"screenshot.elements count={result.Count} total={found->Length} ms={watch.ElapsedMilliseconds}");
            return result;
        }
        catch (Exception ex)
        {
            // UIA 超时、对方进程没响应、窗口已经关了：这扇窗口只认整扇
            Log.Info($"screenshot.elements-failed {ex.GetType().Name} ms={watch.ElapsedMilliseconds}");
            return null;
        }
        finally
        {
            if (found is not null)
            {
                found->Release();
            }

            if (request is not null)
            {
                request->Release();
            }

            if (condition is not null)
            {
                condition->Release();
            }

            if (root is not null)
            {
                root->Release();
            }

            if (automation is not null)
            {
                automation->Release();
            }

            if (initialized)
            {
                PInvoke.CoUninitialize();
            }
        }
    }
}

// 空闲回收（第二版 §4.2 / 同 mac）：所有面板都收起两分钟后，放掉可以重建的东西——
// 剪贴板预览的图片、启动器里暂时不用的图标位图，做大对象堆压缩的 GC。
// 只在「刚收起」时挂一个一次性定时器；再次打开面板就取消，隐藏窗口上不常驻定时器。
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class IdleReclaimer
{
    private const int DelaySeconds = 120;

    private static readonly List<Action> Actions = new();
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer;

    public static void Register(Action action) => Actions.Add(action);

    /// <summary>所有面板收起之后调一次：两分钟后回收。</summary>
    public static void Schedule()
    {
        _timer ??= CreateTimer();
        _timer.Stop();
        _timer.Start();
    }

    /// <summary>又有面板打开了：取消这一轮回收。</summary>
    public static void Cancel() => _timer?.Stop();

    private static Microsoft.UI.Dispatching.DispatcherQueueTimer CreateTimer()
    {
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var timer = dispatcher.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(DelaySeconds);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Run();
        return timer;
    }

    private static void Run()
    {
        var released = 0;
        foreach (var action in Actions)
        {
            try
            {
                action();
                released++;
            }
            catch (Exception ex)
            {
                Log.Warn($"idle.action-failed {ex.GetType().Name}");
            }
        }

        // 大对象堆（截图、图标位图、正文缓冲）做一次压缩回收，量给探针看（PLAN-v2 §4.2）。
        try
        {
            System.Runtime.GCSettings.LargeObjectHeapCompactionMode =
                System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect(2, GCCollectionMode.Optimized, blocking: false, compacting: true);
        }
        catch (Exception ex)
        {
            Log.Warn($"idle.gc-failed {ex.GetType().Name}");
        }

        Log.Info($"idle.reclaim actions={released}");
    }
}

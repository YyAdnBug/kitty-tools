// 进程入口。单实例检查放在 WinUI 启动之前；第二个实例转发「打开设置」后直接退出。
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using KittyTools.Infrastructure;

namespace KittyTools;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // 自动更新换上的新版本要等旧进程退出并放掉互斥量，所以带 --updated 时多等几秒。
        var updated = args.Contains("--updated", StringComparer.OrdinalIgnoreCase);
        if (!SingleInstance.TryStart(updated ? 8000 : 0))
        {
            return 0;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }
}

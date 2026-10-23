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
        if (!SingleInstance.TryStart())
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

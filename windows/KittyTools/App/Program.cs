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
        // 自动更新失败路径的端到端自检（PLAN-v6 第 7 批）：不需要窗口、单实例或 COM，
        // 在真正启动 WinUI 之前跑完就退出，报告写在 --update-e2e 目录里。
        if (UpdateE2E.IsRequested(args))
        {
            return UpdateE2E.Run(args);
        }

        // 对着真 GitHub 走一遍更新的下载和校验（发版前跑，见 UpdateLive）：同样不需要窗口，跑完就退出。
        if (UpdateLive.IsRequested(args))
        {
            return UpdateLive.Run(args);
        }

        // 安装程序（Inno，PLAN-setup-inno §4.2 / §4.3）调的两个：不建窗口、不占单实例、不写数据目录，做完就退。
        if (args.Contains("--quit", StringComparer.OrdinalIgnoreCase))
        {
            SingleInstance.SendQuit();
            return 0;
        }

        if (UninstallCleanup.IsRequested(args))
        {
            return UninstallCleanup.Run(args);
        }

        // 自动更新换上的新版本要等旧进程退出并放掉互斥量，所以带 --updated 时多等几秒；
        // 数据库恢复完重启自己（--restarted，REVIEW R64 B）也一样。
        var updated = args.Contains("--updated", StringComparer.OrdinalIgnoreCase) ||
                      args.Contains("--restarted", StringComparer.OrdinalIgnoreCase);
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

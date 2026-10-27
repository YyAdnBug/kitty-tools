// 单实例：命名互斥量 Local\KittyTools（Debug 版 .Dev）。
// 第二个实例把「打开设置」转给第一个，然后自己退出。
// 管道还认 quit：KittyTools.exe --quit 发来（Inno 安装 / 卸载时调，PLAN-setup-inno I8），走和托盘「退出」一样的 ShellRuntime.Exit。
using System.IO.Pipes;
using System.Text;
using Microsoft.UI.Dispatching;

namespace KittyTools.Infrastructure;

internal static class SingleInstance
{
    private const string ShowSettingsCommand = "show-settings";
    private const string QuitCommand = "quit";

    private static Mutex? _mutex;
    private static volatile bool _stopping;

    /// <summary>
    /// waitMs &gt; 0 时反复试：自动更新会先启动新版本、自己再退出，
    /// 新进程要等旧进程把互斥量放掉（第二版 §5）。
    /// </summary>
    public static bool TryStart(int waitMs = 0)
    {
        var deadline = Environment.TickCount64 + waitMs;
        while (true)
        {
            var mutex = new Mutex(initiallyOwned: true, Paths.MutexName, out var createdNew);
            if (createdNew)
            {
                _mutex = mutex;
                _stopping = false;
                return true;
            }

            mutex.Dispose();
            if (Environment.TickCount64 >= deadline)
            {
                NotifyFirstInstance();
                return false;
            }

            Thread.Sleep(150);
        }
    }

    /// <summary>自动更新替换完文件、要启动新版本之前：把互斥量和转发服务都让出来。</summary>
    public static void Release()
    {
        _stopping = true;
        try
        {
            _mutex?.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // 不是自己持有的（已经放过）就算了。
        }

        _mutex?.Dispose();
        _mutex = null;
    }

    /// <summary>在界面线程上调：quit 要回到这个线程的 DispatcherQueue 上退出。</summary>
    public static void StartServer(Action showSettings)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        Action quit = () => dispatcher?.TryEnqueue(() => ShellRuntime.Instance?.Exit());
        var thread = new Thread(() => ServerLoop(showSettings, quit))
        {
            IsBackground = true,
            Name = "KittyTools.InstanceServer",
        };
        thread.Start();
    }

    /// <summary>--quit：有一个在跑就叫它退出（不等它退完，安装程序自己看互斥量）；连不上管道 = 没有在跑的，什么都不做。</summary>
    public static void SendQuit()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", Paths.InstancePipeName, PipeDirection.Out);
            pipe.Connect(1500);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            writer.WriteLine(QuitCommand);
        }
        catch (Exception)
        {
            // 没有在跑的：本来就不用退。
        }
    }

    private static void NotifyFirstInstance()
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", Paths.InstancePipeName, PipeDirection.Out);
                pipe.Connect(800);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
                writer.WriteLine(ShowSettingsCommand);
                return;
            }
            catch (Exception) when (attempt < 9)
            {
                Thread.Sleep(100);
            }
            catch (Exception ex)
            {
                Log.Error("instance.notify-failed", ex);
                return;
            }
        }
    }

    private static void ServerLoop(Action showSettings, Action quit)
    {
        while (!_stopping)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(
                    Paths.InstancePipeName,
                    PipeDirection.In,
                    1,
                    PipeTransmissionMode.Byte);
                pipe.WaitForConnection();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                var command = reader.ReadLine();
                if (command == ShowSettingsCommand)
                {
                    showSettings();
                }
                else if (command == QuitCommand)
                {
                    Log.Info("instance.quit");
                    quit();
                }
            }
            catch (Exception ex)
            {
                Log.Error("instance.server-failed", ex);
                Thread.Sleep(500);
            }
        }
    }
}

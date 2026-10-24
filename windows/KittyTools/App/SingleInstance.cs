// 单实例：命名互斥量 Local\KittyTools（Debug 版 .Dev）。
// 第二个实例把「打开设置」转给第一个，然后自己退出。
using System.IO.Pipes;
using System.Text;

namespace KittyTools.Infrastructure;

internal static class SingleInstance
{
    private const string ShowSettingsCommand = "show-settings";

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

    public static void StartServer(Action showSettings)
    {
        var thread = new Thread(() => ServerLoop(showSettings))
        {
            IsBackground = true,
            Name = "KittyTools.InstanceServer",
        };
        thread.Start();
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

    private static void ServerLoop(Action showSettings)
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
            }
            catch (Exception ex)
            {
                Log.Error("instance.server-failed", ex);
                Thread.Sleep(500);
            }
        }
    }
}

// 单实例：命名互斥量 Local\KittyTools（Debug 版 .Dev）。
// 第二个实例把「打开设置」转给第一个，然后自己退出。
using System.IO.Pipes;
using System.Text;

namespace KittyTools.Infrastructure;

internal static class SingleInstance
{
    private const string ShowSettingsCommand = "show-settings";

    private static Mutex? _mutex;

    public static bool TryStart()
    {
        _mutex = new Mutex(initiallyOwned: true, Paths.MutexName, out var createdNew);
        if (createdNew)
        {
            return true;
        }

        _mutex.Dispose();
        _mutex = null;
        NotifyFirstInstance();
        return false;
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
        while (true)
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

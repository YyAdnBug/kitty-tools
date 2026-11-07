// 提醒提示音文件的自检（PLAN-v16 E2，Windows 自己加的）：`--reminder-sound-probe=<目录>`（只在测试档）。
// 在 <目录> 里写几个静音的 WAV 和坏文件，走真的 ReminderSound：拷进测试档数据目录的 reminder-sounds\、同名同内容复用、同名不同内容加数字、
// 太大 / 扩展名不对 / 放不出来的不收、列表、放（静音，听不到）、停、只停试听、清掉没在用的。每步写进 <目录>\report.md，跑完退出。
// 系统提示音那条路（PlaySound）不在这里放：会真的响。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class ReminderSoundProbe
{
    public const string ArgumentPrefix = "--reminder-sound-probe";

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path)
            ? Path.Combine(Path.GetTempPath(), "kitty-reminder-sound-probe")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 提醒提示音文件自检（PLAN-v16 E2）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        async Task<string?> Rejected(string path)
        {
            try
            {
                await ReminderSound.ImportAsync(path);
                return null;
            }
            catch (InvalidOperationException ex)
            {
                return ex.Message;
            }
        }

        await Task.Delay(1000);
        try
        {
            if (Directory.Exists(ReminderSound.Folder))
            {
                Directory.Delete(ReminderSound.Folder, recursive: true);
            }

            var first = Path.Combine(directory, "a", "下课铃.wav");
            var second = Path.Combine(directory, "b", "下课铃.wav");
            WriteSilence(first, seconds: 3);
            WriteSilence(second, seconds: 2);

            var id = await ReminderSound.ImportAsync(first);
            Check(id == "file:下课铃.wav" && File.Exists(Path.Combine(ReminderSound.Folder, "下课铃.wav")), $"拷进来：{id}");
            var again = await ReminderSound.ImportAsync(first);
            Check(again == id && Directory.GetFiles(ReminderSound.Folder).Length == 1, $"同名同内容用已有的：{again}");
            var other = await ReminderSound.ImportAsync(second);
            Check(other == "file:下课铃 2.wav", $"同名不同内容加数字：{other}");

            var big = Path.Combine(directory, "大.wav");
            using (var stream = File.Create(big))
            {
                stream.SetLength(Reminders.MaxChimeBytes + 1);
            }

            var bigMessage = await Rejected(big);
            Check(bigMessage?.Contains("20 MB") == true, $"太大不收：{bigMessage}");
            var text = Path.Combine(directory, "说明.txt");
            await File.WriteAllTextAsync(text, "不是声音");
            var textMessage = await Rejected(text);
            Check(textMessage is not null, $"扩展名不对不收：{textMessage}");
            var fake = Path.Combine(directory, "假的.mp3");
            await File.WriteAllTextAsync(fake, "不是声音，只是改了扩展名");
            var fakeMessage = await Rejected(fake);
            Check(fakeMessage is not null && !File.Exists(Path.Combine(ReminderSound.Folder, "假的.mp3")), $"放不出来不收：{fakeMessage}");

            var files = ReminderSound.Files();
            Check(files.SequenceEqual(new[] { id, other }), $"列表：{string.Join("、", files)}");
            Check(ReminderSound.Exists(id) && !ReminderSound.Exists("file:没有.mp3") && ReminderSound.Exists("Glass"), "有没有这个声音");
            Check(Reminders.ChimeTitle(id, ReminderSound.Exists(id)) == "下课铃", "有文件时只写文件名");

            ReminderSound.Play(id, preview: true);
            await Task.Delay(800);
            Check(ReminderSound.IsPlayingForProbe, "试听在放");
            ReminderSound.StopPreview();
            await Task.Delay(300);
            Check(!ReminderSound.IsPlayingForProbe, "关编辑框停试听");

            ReminderSound.Play(other);
            await Task.Delay(800);
            Check(ReminderSound.IsPlayingForProbe, "到点在放");
            ReminderSound.StopPreview();
            await Task.Delay(300);
            Check(ReminderSound.IsPlayingForProbe, "到点的不被关编辑框停掉");
            ReminderSound.Stop();
            await Task.Delay(300);
            Check(!ReminderSound.IsPlayingForProbe, "「知道了」停下");

            ReminderSound.Purge(new[] { id, "Glass", "file:没有.mp3" });
            Check(ReminderSound.Files().SequenceEqual(new[] { id }), $"清掉没在用的：{string.Join("、", ReminderSound.Files())}");
        }
        catch (Exception ex)
        {
            Check(false, $"异常 {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            report.Append($"\n**{(failures == 0 ? "全过" : $"{failures} 条不对")}**\n");
            await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
            Log.Info($"reminder-sound-probe done failures={failures}");
            Environment.Exit(0);
        }
    }

    /// <summary>写一个静音的 16 位单声道 WAV（16 kHz）。</summary>
    private static void WriteSilence(string path, int seconds)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        const int rate = 16000;
        var data = rate * 2 * seconds;
        using var writer = new BinaryWriter(File.Create(path));
        writer.Write("RIFF"u8);
        writer.Write(36 + data);
        writer.Write("WAVEfmt "u8);
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(data);
        writer.Write(new byte[data]);
    }
}

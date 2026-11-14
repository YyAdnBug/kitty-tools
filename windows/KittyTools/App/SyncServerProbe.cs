// PLAN-v19 核验用的自检（只在测试档）：`--sync-server-probe=<目录>`，连 KITTY_SYNC_PROBE 给的 WebDAV 服务器（「地址|用户名|密码|文件夹」，
// 只给本机的测试服务器，不用真账号），走真的 Syncer.EnableServerAsync / RoundAsync。KITTY_SYNC_PROBE_NOTE 给了就先建一条这样的便签，
// KITTY_SYNC_PROBE_IMAGE=1 时便签里再放一张小图（图片走 images\ 的临时名 + MOVE），KITTY_SYNC_PROBE_NOTES=N 再多建 N 条。之后合 KITTY_SYNC_PROBE_ROUNDS 轮（默认 3 轮、
// 隔 4 秒），每轮把状态写进 <目录>\report.md：状态、没拿下来 / 没传上去几个、便签几条、带「probe」的便签正文、图片几张、镜像里还是占位
// （带「脱机」属性）的文件几个。跑完就退；连过的服务器、凭据（Dev 版前缀）由调用方停同步或删档收拾。
using System.Text;
using KittyTools.Core.Notes;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class SyncServerProbe
{
    public const string ArgumentPrefix = "--sync-server-probe";

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
        return string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-sync-server-probe") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder($"# 连服务器同步自检（{Paths.DataDirectory}）\n\n");
        try
        {
            await Task.Delay(3000);
            if (Syncer.Instance is not { } syncer)
            {
                report.Append("- 没有 Syncer\n");
                return;
            }

            if (!Syncer.IsServer)
            {
                var parts = (Environment.GetEnvironmentVariable("KITTY_SYNC_PROBE") ?? string.Empty).Split('|');
                if (parts.Length < 4 || WebDav.Folder(parts[0], parts[3]) is not { } folder)
                {
                    report.Append("- KITTY_SYNC_PROBE 没给对（地址|用户名|密码|文件夹）\n");
                    return;
                }

                var problem = await syncer.EnableServerAsync(new WebDavAccount(folder, parts[1], parts[2]));
                report.Append($"- 连接：{problem ?? "成了"}\n");
                if (problem is not null)
                {
                    return;
                }
            }
            else
            {
                report.Append("- 已经连着服务器\n");
            }

            if (Environment.GetEnvironmentVariable("KITTY_SYNC_PROBE_NOTE") is { Length: > 0 } text && NoteStore.Instance is { } store)
            {
                var body = text;
                if (Environment.GetEnvironmentVariable("KITTY_SYNC_PROBE_IMAGE") == "1" && store.Images is { } images)
                {
                    var stored = await NoteImageStore.StoreBytesAsync(SamplePng(), images.Directory);
                    if (stored.Stored is { } image)
                    {
                        images.Remember(image);
                        body += "\n" + NoteImages.Token(image.Image);
                    }

                    report.Append($"- 图：{(stored.Stored is null ? stored.Rejection.ToString() : "放进便签")}\n");
                }

                var note = store.Create(body);
                // KITTY_SYNC_PROBE_NOTES=N：再建 N 条（一轮最多 40 个请求，多了另一台第一轮拿不完，看占位和「还有 N 个没拿下来」）
                var extra = int.TryParse(Environment.GetEnvironmentVariable("KITTY_SYNC_PROBE_NOTES"), out var more) ? more : 0;
                for (var index = 0; index < extra; index++)
                {
                    store.Create($"{text} {index + 1}");
                }

                store.Flush();
                report.Append($"- 建了 {1 + extra} 条便签（第一条 {note.Id}）\n");
            }

            var rounds = int.TryParse(Environment.GetEnvironmentVariable("KITTY_SYNC_PROBE_ROUNDS"), out var count) ? count : 3;
            for (var round = 1; round <= rounds; round++)
            {
                var started = Environment.TickCount64;
                await syncer.RoundAsync();
                var status = syncer.Status;
                var notes = NoteStore.Instance?.Book.All.Where(note => note.DeletedAt is null).ToList() ?? new();
                // 带 probe 的便签：只列每台建的那第一条（KITTY_SYNC_PROBE_NOTES 多建的只算个数）
                var probeNotes = notes.Where(note => note.Body.Contains("probe", StringComparison.Ordinal))
                    .Select(note => note.Body.Split('\n')[0]).ToList();
                var firsts = probeNotes.Where(line => line.EndsWith("便签", StringComparison.Ordinal)).OrderBy(line => line, StringComparer.Ordinal);
                var imageCount = NoteStore.Instance?.Images is { } store2 && Directory.Exists(store2.Directory)
                    ? Directory.EnumerateFiles(store2.Directory).Count(file => !Path.GetFileName(file).StartsWith('.'))
                    : 0;
                report.Append($"- 第 {round} 轮（{Environment.TickCount64 - started} ms）：{status.State}「{status.Message}」没拿下来 {status.Downloading}、" +
                              $"没传上去 {status.Uploading}；便签 {notes.Count} 条，图片 {imageCount} 张，镜像里的占位 {Placeholders()} 个；" +
                              $"带 probe 的 {probeNotes.Count} 条：{string.Join(" / ", firsts)}\n");
                await Task.Delay(4000);
            }
        }
        catch (Exception ex)
        {
            report.Append($"- 出错 {ex.GetType().Name}\n");
        }
        finally
        {
            await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
            Log.Info("sync-server-probe done");
            Environment.Exit(0);
        }
    }

    /// <summary>镜像里带「脱机」属性的占位文件（PLAN-v19 W1：没拿下来的）。</summary>
    private static int Placeholders()
    {
        if (SettingsService.Current.SyncFolder is not { } mirror || !Directory.Exists(mirror))
        {
            return 0;
        }

        return Directory.EnumerateFiles(mirror, "*", SearchOption.AllDirectories)
            .Count(file => File.GetAttributes(file).HasFlag(FileAttributes.Offline));
    }

    /// <summary>一张 4 × 4 的红色 PNG。</summary>
    private static byte[] SamplePng() => Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR4nGP4z8AARwgWXg4ArpMP8aaUSCMAAAAASUVORK5CYII=");
}

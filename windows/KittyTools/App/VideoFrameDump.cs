// 自检（Debug）：`--video-frames=<mp4>|<目录>|<每几帧存一张>` 逐帧解码（VideoFrames），每帧的时间戳和整帧平均亮度写进
// <目录>/frames.csv，每隔几帧另存一张 PNG（frame-<序号>-<毫秒>.png）。看动效的短视频、查录下来的时间戳用。
using System.Globalization;
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Storage;

namespace KittyTools;

internal static class VideoFrameDump
{
    public const string ArgumentPrefix = "--video-frames=";

    public static async Task RunAsync(string argument)
    {
        var parts = argument.Split('|');
        var path = parts[0];
        var directory = parts.Length > 1 ? parts[1] : Path.Combine(Path.GetDirectoryName(path)!, "frames");
        var every = parts.Length > 2 && int.TryParse(parts[2], out var value) && value > 0 ? value : 1;
        Directory.CreateDirectory(directory);
        var lines = new List<string> { "index,seconds,luma" };
        var pending = new List<(int Index, double Seconds, byte[] Pixels, int Width, int Height)>();
        var index = 0;
        var count = await Task.Run(() => VideoFrames.Read(Path.GetFullPath(path), (seconds, bgra, width, height) =>
        {
            double sum = 0;
            for (var i = 0; i < bgra.Length; i += 16)
            {
                sum += 0.114 * bgra[i] + 0.587 * bgra[i + 1] + 0.299 * bgra[i + 2];
            }

            lines.Add(string.Create(CultureInfo.InvariantCulture, $"{index},{seconds:F4},{sum / (bgra.Length / 16.0):F1}"));
            if (index % every == 0)
            {
                pending.Add((index, seconds, bgra.ToArray(), width, height));
            }

            index++;
        }));
        await File.WriteAllLinesAsync(Path.Combine(directory, "frames.csv"), lines);
        foreach (var frame in pending)
        {
            var file = await (await StorageFolder.GetFolderFromPathAsync(Path.GetFullPath(directory)))
                .CreateFileAsync($"frame-{frame.Index:D4}-{frame.Seconds * 1000:F0}.png", CreationCollisionOption.ReplaceExisting);
            using var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)frame.Width, (uint)frame.Height,
                96, 96, frame.Pixels);
            await encoder.FlushAsync();
        }

        Log.Info($"video-frames.done frames={count} saved={pending.Count}");
    }
}

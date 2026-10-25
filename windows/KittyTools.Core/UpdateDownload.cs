// 流式下载的落盘部分（REVIEW R3，配单测）：先写 <文件名>.partial，写完才改名；
// 失败、取消、抛异常都删掉半成品。下载内容一律按 80 KB 一块复制，不整块读进内存。
// 网络 / 本地来源由调用方给一个打开流的工厂，这一层只管写盘和收尾，所以能在单测里用假流跑。
namespace KittyTools.Core;

public static class UpdateDownload
{
    public const int BufferSize = 81920;

    public static string PartialPath(string path) => path + ".partial";

    /// <summary>
    /// 从 <paramref name="openSource"/> 拿到的流复制到 <paramref name="path"/>：
    /// 先写 .partial，成功才 File.Move 换上去；任何异常 / 取消都删掉 .partial，不留残渣。
    /// <paramref name="progress"/> 收到「已复制字节 / 总字节（可能不知道）」。
    /// </summary>
    public static async Task WriteAsync(
        string path,
        Func<CancellationToken, Task<Stream>> openSource,
        Action<long, long?>? progress = null,
        CancellationToken cancellationToken = default,
        long? knownTotal = null)
    {
        var partial = PartialPath(path);
        TryDelete(partial);
        try
        {
            await using var source = await openSource(cancellationToken);
            await using var target = new FileStream(
                partial, FileMode.Create, FileAccess.Write, FileShare.None, BufferSize, useAsync: true);
            // 网络流的 CanSeek 是 false，Content-Length 要由调用方给（REVIEW R11：否则托盘只显示「正在下载…」）。
            long? total = knownTotal ?? (source.CanSeek ? source.Length : null);
            await CopyAsync(source, target, progress, total, cancellationToken);
            await target.FlushAsync(cancellationToken);
            target.Close();
            File.Move(partial, path, overwrite: true);
        }
        catch
        {
            TryDelete(partial);
            throw;
        }
    }

    /// <summary>80 KB 一块的复制（不走 MemoryStream，不整块读）。</summary>
    public static async Task CopyAsync(
        Stream source,
        Stream target,
        Action<long, long?>? progress,
        long? total,
        CancellationToken cancellationToken = default)
    {
        var buffer = new byte[BufferSize];
        long received = 0;
        while (true)
        {
            var read = await source.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (read == 0)
            {
                break;
            }

            await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            received += read;
            progress?.Invoke(received, total);
        }

        progress?.Invoke(received, total);
    }

    public static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // 删不掉就留着，下一次写同一个文件前会再清一次。
        }
    }
}

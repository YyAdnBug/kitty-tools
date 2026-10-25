// REVIEW R3 的单测：流式写 <文件名>.partial、写完才改名；失败 / 取消都删掉半成品。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class UpdateDownloadTests
{
    private static string NewDirectory()
    {
        var directory = Path.Combine(Path.GetTempPath(), "kitty-download-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        return directory;
    }

    [TestMethod]
    public async Task WritesPartialThenRenames()
    {
        var directory = NewDirectory();
        try
        {
            var target = Path.Combine(directory, "KittyTools.zip");
            var payload = new byte[300_000];
            Random.Shared.NextBytes(payload);
            var progress = new List<long>();
            await UpdateDownload.WriteAsync(
                target,
                _ => Task.FromResult<Stream>(new MemoryStream(payload)),
                (received, total) =>
                {
                    Assert.AreEqual(payload.Length, total);
                    progress.Add(received);
                });

            Assert.IsTrue(File.Exists(target));
            CollectionAssert.AreEqual(payload, File.ReadAllBytes(target));
            Assert.IsFalse(File.Exists(UpdateDownload.PartialPath(target)));
            // 每 80 KB 一次，最后一次是完整长度。
            Assert.AreEqual(payload.Length, progress[^1]);
            Assert.IsTrue(progress.Count >= 3, $"progress={progress.Count}");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task FailureLeavesNoPartial()
    {
        var directory = NewDirectory();
        try
        {
            var target = Path.Combine(directory, "KittyTools.zip");
            await Assert.ThrowsExactlyAsync<IOException>(() => UpdateDownload.WriteAsync(
                target,
                _ => Task.FromResult<Stream>(new FailingStream(100_000))));

            Assert.IsFalse(File.Exists(target));
            Assert.IsFalse(File.Exists(UpdateDownload.PartialPath(target)));
            Assert.AreEqual(0, Directory.GetFiles(directory).Length);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task CancellationLeavesNoPartial()
    {
        var directory = NewDirectory();
        try
        {
            var target = Path.Combine(directory, "KittyTools.zip");
            using var cts = new CancellationTokenSource();
            cts.Cancel();
            await Assert.ThrowsExactlyAsync<TaskCanceledException>(() => UpdateDownload.WriteAsync(
                target,
                _ => Task.FromResult<Stream>(new MemoryStream(new byte[200_000])),
                cancellationToken: cts.Token));

            Assert.IsFalse(File.Exists(target));
            Assert.IsFalse(File.Exists(UpdateDownload.PartialPath(target)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task OldPartialIsReplacedNotAppended()
    {
        var directory = NewDirectory();
        try
        {
            var target = Path.Combine(directory, "KittyTools.zip");
            var partial = UpdateDownload.PartialPath(target);
            await File.WriteAllBytesAsync(partial, new byte[5000]);
            await UpdateDownload.WriteAsync(
                target,
                _ => Task.FromResult<Stream>(new MemoryStream(new byte[1000])));

            Assert.AreEqual(1000, new FileInfo(target).Length);
            Assert.IsFalse(File.Exists(partial));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>读了一部分就抛 IO 错误的流（模拟断网）。</summary>
    private sealed class FailingStream(int failAfter) : Stream
    {
        private int _read;

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_read >= failAfter)
            {
                throw new IOException("connection lost");
            }

            var take = Math.Min(count, failAfter - _read);
            _read += take;
            return take;
        }

        public override long Seek(long offset, SeekOrigin loc) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}

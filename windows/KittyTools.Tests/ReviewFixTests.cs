// REVIEW R6 / R7 / R11 的纯函数单测：进程归属、按行高算面板高度、下载时总大小可以从外面给。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ProcessTreeTests
{
    [TestMethod]
    public void WalksUpPastEmbedders()
    {
        var processes = new Dictionary<uint, (uint Parent, string Name)>
        {
            [10] = (1, "Teams.exe"),
            [11] = (10, "msedgewebview2.exe"),
            [12] = (11, "msedgewebview2.exe"),
            [13] = (12, "msedgewebview2.exe"),
        };
        Assert.AreEqual(10u, ProcessTree.Resolve(13, processes));
        Assert.AreEqual(10u, ProcessTree.Resolve(10, processes));
    }

    [TestMethod]
    public void OrdinaryProcessIsItself()
    {
        var processes = new Dictionary<uint, (uint Parent, string Name)>
        {
            [20] = (1, "notepad.exe"),
        };
        Assert.AreEqual(20u, ProcessTree.Resolve(20, processes));
    }

    [TestMethod]
    public void MissingProcessOrCycleStops()
    {
        var processes = new Dictionary<uint, (uint Parent, string Name)>
        {
            [30] = (31, "msedgewebview2.exe"),
            [31] = (30, "msedgewebview2.exe"),
        };
        var resolved = ProcessTree.Resolve(30, processes);
        Assert.IsTrue(resolved is 30 or 31);
        Assert.AreEqual(99u, ProcessTree.Resolve(99, processes));
    }

    [TestMethod]
    public void EmbedderNamesAreCaseInsensitive()
    {
        Assert.IsTrue(ProcessTree.IsEmbedder("MSEDGEWEBVIEW2.EXE"));
        Assert.IsTrue(ProcessTree.IsEmbedder("ApplicationFrameHost.exe"));
        Assert.IsFalse(ProcessTree.IsEmbedder("chrome.exe"));
        Assert.IsFalse(ProcessTree.IsEmbedder(null));
    }
}

[TestClass]
public sealed class UpdateDownloadTotalTests
{
    [TestMethod]
    public async Task KnownTotalIsReportedForNonSeekableStreams()
    {
        var directory = Path.Combine(Path.GetTempPath(), "kitty-total-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var target = Path.Combine(directory, "payload.bin");
            long? reported = null;
            await UpdateDownload.WriteAsync(
                target,
                _ => Task.FromResult<Stream>(new NonSeekableStream(new byte[1234])),
                (_, total) => reported = total,
                knownTotal: 1234);

            Assert.AreEqual(1234L, reported);
            Assert.AreEqual(1234, new FileInfo(target).Length);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private sealed class NonSeekableStream(byte[] data) : Stream
    {
        private readonly MemoryStream _inner = new(data);

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

        public override int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);

        public override long Seek(long offset, SeekOrigin loc) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}

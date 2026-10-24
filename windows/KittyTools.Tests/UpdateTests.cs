// 自动更新的纯逻辑单测：.sha256 解析 / 文件哈希、覆盖安装的成功与回滚、新版本启动后的 .old 清理。
// 第二版 §5 的验收要求「成功、校验失败、改名失败」三条路都能回到原样，这里覆盖后两条。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class UpdateHashTests
{
    [TestMethod]
    public void ParsesSha256SumFormat()
    {
        var x64 = new string('a', 64);
        var arm64 = new string('b', 64);
        var text = $"""
            {x64}  KittyTools-0.1.1-windows-x64.zip
            {arm64}  KittyTools-0.1.1-windows-arm64.zip
            """;
        Assert.AreEqual(x64, UpdateHash.ExpectedFor(text, "KittyTools-0.1.1-windows-x64.zip"));
        Assert.AreEqual(arm64, UpdateHash.ExpectedFor(text, "KittyTools-0.1.1-windows-arm64.zip"));
        // 没有这个文件就返回 null：宁可不更新。
        Assert.IsNull(UpdateHash.ExpectedFor(text, "KittyTools-0.1.1-windows-x86.zip"));
    }

    [TestMethod]
    public void AcceptsBareHashAndRejectsJunk()
    {
        var hash = new string('a', 64);
        Assert.AreEqual(hash, UpdateHash.ExpectedFor(hash, "anything.zip"));
        Assert.AreEqual(hash, UpdateHash.ExpectedFor("  " + hash + "\r\n", "x.zip"));
        Assert.IsNull(UpdateHash.ExpectedFor("not a hash", "x.zip"));
        Assert.IsNull(UpdateHash.ExpectedFor(string.Empty, "x.zip"));
        Assert.IsFalse(UpdateHash.IsHex(new string('z', 64)));
    }

    [TestMethod]
    public void ComputesAndComparesFileHash()
    {
        var directory = Path.Combine(Path.GetTempPath(), "kitty-update-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var file = Path.Combine(directory, "payload.bin");
            File.WriteAllText(file, "kitty");
            var hash = UpdateHash.ComputeFile(file);
            Assert.AreEqual(64, hash.Length);
            Assert.IsTrue(UpdateHash.FileMatches(file, hash));
            Assert.IsTrue(UpdateHash.FileMatches(file, hash.ToUpperInvariant()));

            File.WriteAllText(file, "tampered");
            Assert.IsFalse(UpdateHash.FileMatches(file, hash));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}

[TestClass]
public sealed class UpdateInstallerTests
{
    private string _root = string.Empty;

    [TestInitialize]
    public void Setup()
    {
        _root = Path.Combine(Path.GetTempPath(), "kitty-install-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(_root, "staging", "Kitty Tools"));
        Directory.CreateDirectory(Path.Combine(_root, "install"));
    }

    [TestCleanup]
    public void Cleanup()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch
        {
            // 测试目录删不掉无所谓。
        }
    }

    private string Stage(string relative, string content)
    {
        var path = Path.Combine(_root, "staging", "Kitty Tools", relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    private string Install(string relative, string content)
    {
        var path = Path.Combine(_root, "install", relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    [TestMethod]
    public void FindsEntryDirectoryInsideTheZipFolder()
    {
        Stage("KittyTools.exe", "new");
        Assert.AreEqual(
            Path.Combine(_root, "staging", "Kitty Tools"),
            UpdateInstaller.FindEntryDirectory(Path.Combine(_root, "staging"), "KittyTools.exe"));
        Assert.IsNull(UpdateInstaller.FindEntryDirectory(Path.Combine(_root, "staging", "Kitty Tools"), "Nope.exe"));
    }

    [TestMethod]
    public void InstallCopiesEverythingAndKeepsOldFiles()
    {
        Stage("KittyTools.exe", "new-exe");
        Stage("Resources/changelog.json", "new-changelog");
        Install("KittyTools.exe", "old-exe");
        Install("leftover.txt", "untouched");

        var result = UpdateInstaller.Install(
            Path.Combine(_root, "staging", "Kitty Tools"), Path.Combine(_root, "install"));

        Assert.IsTrue(result.Ok, result.Error);
        Assert.AreEqual("new-exe", File.ReadAllText(Path.Combine(_root, "install", "KittyTools.exe")));
        Assert.AreEqual(
            "new-changelog", File.ReadAllText(Path.Combine(_root, "install", "Resources", "changelog.json")));
        // 旧 exe 改名成 .old 留着（新进程启动后再删）。
        Assert.AreEqual("old-exe", File.ReadAllText(Path.Combine(_root, "install", "KittyTools.exe.old")));
        // 安装目录里多出来的文件不动。
        Assert.IsTrue(File.Exists(Path.Combine(_root, "install", "leftover.txt")));
    }

    [TestMethod]
    public void FailedCopyRollsEverythingBack()
    {
        Stage("KittyTools.exe", "new-exe");
        Stage("KittyTools.Core.dll", "new-dll");
        var oldExe = Install("KittyTools.exe", "old-exe");
        var oldDll = Install("KittyTools.Core.dll", "old-dll");

        // 占住第二个目标文件、不许别人写：拷贝到它时会失败（模拟「改名 / 拷贝失败」那条路）。
        using (var locked = new FileStream(oldDll, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var result = UpdateInstaller.Install(
                Path.Combine(_root, "staging", "Kitty Tools"), Path.Combine(_root, "install"));

            Assert.IsFalse(result.Ok);
            Assert.IsFalse(string.IsNullOrEmpty(result.Error));
        }

        // 回滚之后旧版本原样都在，没有 .old、没有半截新文件。
        Assert.AreEqual("old-exe", File.ReadAllText(oldExe));
        Assert.AreEqual("old-dll", File.ReadAllText(oldDll));
        Assert.IsFalse(File.Exists(oldExe + UpdateInstaller.OldSuffix));
        Assert.IsFalse(File.Exists(oldDll + UpdateInstaller.OldSuffix));
    }

    [TestMethod]
    public void RemoveOldFilesCleansUp()
    {
        Install("KittyTools.exe.old", "old");
        Install("Resources/KittyTools.Core.dll.old", "old");
        Assert.AreEqual(2, UpdateInstaller.RemoveOldFiles(Path.Combine(_root, "install")));
        Assert.AreEqual(0, UpdateInstaller.RemoveOldFiles(Path.Combine(_root, "install")));
    }

    [TestMethod]
    public void WriteProbeDetectsMissingDirectory()
    {
        Assert.IsTrue(UpdateInstaller.CanWriteInstallDirectory(Path.Combine(_root, "install")));
        Assert.IsFalse(UpdateInstaller.CanWriteInstallDirectory(Path.Combine(_root, "missing")));
    }
}

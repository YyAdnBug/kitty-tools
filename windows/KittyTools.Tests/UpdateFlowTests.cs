// UpdateFlow 的端到端单测（PLAN-v6 第 7 批的「更新失败脚本」）：
// 真的建 zip、真的解压、真的覆盖临时安装目录，只把网络换成文件拷贝。
// 三条必须自动验的路：成功、sha256 错、替换时目标被占用（目录挡路）回滚。
using System.IO.Compression;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class UpdateFlowTests
{
    private string _root = string.Empty;
    private string _staging = string.Empty;
    private string _install = string.Empty;
    private string _downloads = string.Empty;
    private string _zip = string.Empty;
    private string _hash = string.Empty;

    private const string AssetName = "KittyTools-0.2.0-windows-x64.zip";

    [TestInitialize]
    public void Setup()
    {
        _root = Path.Combine(Path.GetTempPath(), "kitty-flow-test-" + Guid.NewGuid().ToString("N"));
        _staging = Path.Combine(_root, "staging");
        _install = Path.Combine(_root, "install");
        _downloads = Path.Combine(_root, "downloads");
        Directory.CreateDirectory(_staging);
        Directory.CreateDirectory(_install);
        Directory.CreateDirectory(_downloads);
        _zip = Path.Combine(_downloads, "source-" + AssetName);
        _hash = Path.Combine(_downloads, AssetName + ".sha256");
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
            // 临时目录删不掉无所谓（被占用的文件由测试自己解释）。
        }
    }

    private void BuildPackage(params (string Name, string Content)[] files)
    {
        var source = Path.Combine(_root, "package", "Kitty Tools");
        Directory.CreateDirectory(source);
        foreach (var (name, content) in files)
        {
            var path = Path.Combine(source, name);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, content);
        }

        ZipFile.CreateFromDirectory(Path.Combine(_root, "package"), _zip);
        File.WriteAllText(
            _hash,
            $"{UpdateHash.ComputeFile(_zip)}  {AssetName}\r\n");
    }

    private void Place(string name, string content)
    {
        var path = Path.Combine(_install, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
    }

    private Task DownloadAsync(string url, string path, Action<long, long?>? progress, CancellationToken token)
    {
        File.Copy(_zip, path, overwrite: true);
        progress?.Invoke(new FileInfo(path).Length, new FileInfo(path).Length);
        return Task.CompletedTask;
    }

    private Task<string> ReadHashAsync(string url, CancellationToken token) => File.ReadAllTextAsync(_hash, token);

    private UpdatePlan Plan() => new("0.2.0", "file:///unused.zip", "file:///unused.sha256", AssetName);

    private Task<UpdateFlowResult> RunAsync(Func<string, Version?>? readVersion = null, string? hashOverride = null)
    {
        if (hashOverride is not null)
        {
            File.WriteAllText(_hash, hashOverride);
        }

        return UpdateFlow.RunAsync(
            Plan(),
            _downloads,
            _staging,
            _install,
            DownloadAsync,
            ReadHashAsync,
            readVersion ?? (_ => new Version(0, 2, 0)));
    }

    [TestMethod]
    public async Task SuccessInstallsAndLeavesOldForRelaunch()
    {
        BuildPackage(("KittyTools.exe", "new-exe"), ("KittyTools.Core.dll", "new-dll"));
        Place("KittyTools.exe", "old-exe");
        Place("KittyTools.Core.dll", "old-dll");

        var result = await RunAsync();

        Assert.IsTrue(result.Ok, result.Error);
        Assert.AreEqual(UpdateStep.Install, result.Step);
        Assert.AreEqual("new-exe", File.ReadAllText(Path.Combine(_install, "KittyTools.exe")));
        Assert.AreEqual("new-dll", File.ReadAllText(Path.Combine(_install, "KittyTools.Core.dll")));
        // 旧文件改名成 .old，等新进程启动后清掉。
        Assert.AreEqual("old-exe", File.ReadAllText(Path.Combine(_install, "KittyTools.exe" + UpdateInstaller.OldSuffix)));
        Assert.AreEqual(2, UpdateInstaller.RemoveOldFiles(_install));
        // 下载的 zip 不留。
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName)));
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName + ".partial")));
    }

    [TestMethod]
    public async Task Sha256MismatchLeavesInstallUntouched()
    {
        BuildPackage(("KittyTools.exe", "new-exe"), ("KittyTools.Core.dll", "new-dll"));
        Place("KittyTools.exe", "old-exe");
        Place("KittyTools.Core.dll", "old-dll");

        var result = await RunAsync(hashOverride: new string('0', 64));

        Assert.IsFalse(result.Ok);
        Assert.AreEqual(UpdateStep.Hash, result.Step);
        Assert.AreEqual("old-exe", File.ReadAllText(Path.Combine(_install, "KittyTools.exe")));
        Assert.AreEqual("old-dll", File.ReadAllText(Path.Combine(_install, "KittyTools.Core.dll")));
        Assert.IsFalse(File.Exists(Path.Combine(_install, "KittyTools.exe" + UpdateInstaller.OldSuffix)));
        Assert.IsFalse(File.Exists(Path.Combine(_install, "KittyTools.Core.dll" + UpdateInstaller.OldSuffix)));
        // 校验失败也不能把半成品留在 updates\。
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName)));
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName + ".partial")));
    }

    [TestMethod]
    public async Task BlockedTargetRollsBackEveryFile()
    {
        BuildPackage(("KittyTools.exe", "new-exe"), ("KittyTools.Core.dll", "new-dll"));
        Place("KittyTools.exe", "old-exe");
        // 真机等价情形：目标位置被一个同名目录挡住，拷贝必然失败（HANDTEST §127 的做法）。
        var blocked = Path.Combine(_install, "KittyTools.Core.dll");
        Directory.CreateDirectory(blocked);
        File.WriteAllText(Path.Combine(blocked, "keep.txt"), "keep");

        var result = await RunAsync();

        Assert.IsFalse(result.Ok);
        Assert.AreEqual(UpdateStep.Install, result.Step);
        Assert.AreEqual("old-exe", File.ReadAllText(Path.Combine(_install, "KittyTools.exe")));
        Assert.IsFalse(File.Exists(Path.Combine(_install, "KittyTools.exe" + UpdateInstaller.OldSuffix)));
        // 挡住的那个目录原样还在，没有被当文件删掉。
        Assert.IsTrue(Directory.Exists(blocked));
        Assert.AreEqual("keep", File.ReadAllText(Path.Combine(blocked, "keep.txt")));
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName)));
    }

    [TestMethod]
    public async Task WrongStagedVersionIsRejectedBeforeInstall()
    {
        BuildPackage(("KittyTools.exe", "new-exe"), ("KittyTools.Core.dll", "new-dll"));
        Place("KittyTools.exe", "old-exe");

        var result = await RunAsync(_ => new Version(9, 9, 9));

        Assert.IsFalse(result.Ok);
        Assert.AreEqual(UpdateStep.Version, result.Step);
        Assert.AreEqual("old-exe", File.ReadAllText(Path.Combine(_install, "KittyTools.exe")));
        Assert.IsFalse(File.Exists(Path.Combine(_install, "KittyTools.exe" + UpdateInstaller.OldSuffix)));
    }

    [TestMethod]
    public async Task DownloadFailureLeavesNoPartial()
    {
        var result = await UpdateFlow.RunAsync(
            Plan(),
            _downloads,
            _staging,
            _install,
            (_, _, _, _) => throw new IOException("network down"),
            ReadHashAsync,
            _ => new Version(0, 2, 0));

        Assert.IsFalse(result.Ok);
        Assert.AreEqual(UpdateStep.Download, result.Step);
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName)));
        Assert.IsFalse(File.Exists(Path.Combine(_downloads, AssetName + ".partial")));
        Assert.IsEmpty(Directory.EnumerateFiles(_install));
    }
}

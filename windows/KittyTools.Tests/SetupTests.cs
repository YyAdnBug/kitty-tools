// 安装程序（PLAN-setup §5）的纯函数单测：载荷尾巴、路径规则、卸载前的检查、注册表值和测试用的名字。
// 只在临时目录里写假的本体和 zip，不碰注册表、开始菜单和用户数据。
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SetupPayloadTests
{
    private string _folder = string.Empty;

    [TestInitialize]
    public void Create()
    {
        _folder = Path.Combine(Path.GetTempPath(), "kitty-setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_folder);
    }

    [TestCleanup]
    public void Remove() => Directory.Delete(_folder, recursive: true);

    [TestMethod]
    public void PackThenReadBack()
    {
        var stub = Encoding.ASCII.GetBytes("MZ fake stub " + new string('x', 1000));
        var (setup, zip) = Pack(stub);

        using var file = File.OpenRead(setup);
        var trailer = SetupPayload.ReadTrailer(file);
        Assert.IsNotNull(trailer);
        Assert.AreEqual(stub.Length, trailer.PayloadOffset);
        Assert.AreEqual(new FileInfo(zip).Length, trailer.PayloadLength);
        Assert.AreEqual(stub.Length + trailer.PayloadLength + SetupPayload.TrailerSize, file.Length);
        CollectionAssert.AreEqual(SHA256.HashData(File.ReadAllBytes(zip)), trailer.Sha256);
        Assert.IsTrue(SetupPayload.Verify(file, trailer));

        // 载荷能直接当 zip 读（ZipArchive 会从末尾往前 Seek）。
        using (var archive = new ZipArchive(SetupPayload.OpenPayload(file, trailer), ZipArchiveMode.Read))
        {
            var entry = archive.GetEntry("Kitty Tools/KittyTools.exe");
            Assert.IsNotNull(entry);
            using var reader = new StreamReader(entry.Open());
            Assert.AreEqual("new exe", reader.ReadToEnd());
        }

        // 复制成 Uninstall.exe：只有本体，没有尾巴。
        using var copy = new MemoryStream();
        SetupPayload.CopyPrefix(file, trailer.PayloadOffset, copy);
        CollectionAssert.AreEqual(stub, copy.ToArray());
        copy.Position = 0;
        Assert.IsNull(SetupPayload.ReadTrailer(copy));
    }

    [TestMethod]
    public void BadMarkerMeansNoPayload()
    {
        var (setup, _) = Pack(new byte[200]);
        var bytes = File.ReadAllBytes(setup);
        bytes[^SetupPayload.TrailerSize] = (byte)'X';
        using var file = new MemoryStream(bytes);
        Assert.IsNull(SetupPayload.ReadTrailer(file));
        Assert.IsNull(SetupPayload.ReadTrailer(new MemoryStream(new byte[10])));
    }

    [TestMethod]
    public void OffsetAndLengthMustFitTheFile()
    {
        var hash = new byte[32];
        const long fileLength = 1000;
        const long end = fileLength - SetupPayload.TrailerSize;
        Assert.IsNotNull(Parse(new SetupTrailer(100, end - 100, hash), fileLength));
        // 长度越界、起点越界、没贴着尾巴、本体为空、长度为 0、相加溢出。
        Assert.IsNull(Parse(new SetupTrailer(100, end, hash), fileLength));
        Assert.IsNull(Parse(new SetupTrailer(end, 1, hash), fileLength));
        Assert.IsNull(Parse(new SetupTrailer(100, end - 101, hash), fileLength));
        Assert.IsNull(Parse(new SetupTrailer(0, end, hash), fileLength));
        Assert.IsNull(Parse(new SetupTrailer(end, 0, hash), fileLength));
        Assert.IsNull(Parse(new SetupTrailer(long.MaxValue, long.MaxValue, hash), fileLength));
    }

    [TestMethod]
    public void WrongShaIsRejected()
    {
        var (setup, _) = Pack(new byte[300]);
        var bytes = File.ReadAllBytes(setup);
        bytes[310] ^= 0xFF; // 载荷中间改一个字节
        using var file = new MemoryStream(bytes);
        var trailer = SetupPayload.ReadTrailer(file);
        Assert.IsNotNull(trailer);
        Assert.IsFalse(SetupPayload.Verify(file, trailer));
    }

    [TestMethod]
    public void StubThatAlreadyHasAPayloadIsRefused()
    {
        var (setup, zip) = Pack(new byte[100]);
        Assert.ThrowsExactly<InvalidDataException>(
            () => SetupPayload.Pack(setup, zip, Path.Combine(_folder, "twice.exe")));
    }

    private static SetupTrailer? Parse(SetupTrailer trailer, long fileLength)
        => SetupPayload.ParseTrailer(SetupPayload.BuildTrailer(trailer), fileLength);

    private (string Setup, string Zip) Pack(byte[] stub)
    {
        var stubPath = Path.Combine(_folder, "stub-" + Guid.NewGuid().ToString("N") + ".exe");
        File.WriteAllBytes(stubPath, stub);
        var zip = Path.Combine(_folder, "payload.zip");
        if (!File.Exists(zip))
        {
            using var archive = ZipFile.Open(zip, ZipArchiveMode.Create);
            using var writer = new StreamWriter(archive.CreateEntry("Kitty Tools/KittyTools.exe").Open());
            writer.Write("new exe");
        }

        var setup = Path.Combine(_folder, "setup-" + Guid.NewGuid().ToString("N") + ".exe");
        SetupPayload.Pack(stubPath, zip, setup);
        Assert.IsFalse(File.Exists(setup + ".partial"));
        return (setup, zip);
    }
}

[TestClass]
public sealed class SetupRulesTests
{
    private static readonly SetupFolders Folders = new(
        [@"C:\Windows", @"C:\Program Files", @"C:\Program Files (x86)"],
        [@"C:\Users\yy", @"C:\Users\yy\Desktop", @"C:\Users\yy\Documents", @"C:\Users\yy\Downloads"]);

    [TestMethod]
    public void ResolveAddsKittyToolsFolder()
    {
        Assert.AreEqual(@"D:\Apps\Kitty Tools", SetupRules.ResolveInstallDir(@"D:\Apps"));
        Assert.AreEqual(@"D:\Apps\Kitty Tools", SetupRules.ResolveInstallDir(@"D:\Apps\"));
        Assert.AreEqual(@"D:\Apps\kitty tools", SetupRules.ResolveInstallDir(@"D:\Apps\kitty tools\"));
        Assert.AreEqual(@"D:\Apps\Kitty Tools", SetupRules.ResolveInstallDir("D:/Apps/Kitty Tools"));
        Assert.AreEqual(@"D:\Kitty Tools", SetupRules.ResolveInstallDir(@"D:\"));
        Assert.AreEqual(@"D:\Kitty Tools", SetupRules.ResolveInstallDir("D:"));
        Assert.AreEqual(@"D:\Kitty Tools Old\Kitty Tools", SetupRules.ResolveInstallDir(@"D:\Kitty Tools Old"));
    }

    [TestMethod]
    public void ForbiddenFolders()
    {
        foreach (var dir in new[]
                 {
                     @"C:\", "D:", @"C:\Windows", @"C:\windows\Kitty Tools", @"C:\Program Files\Kitty Tools",
                     @"C:\Program Files (x86)\Apps\Kitty Tools", @"C:\Users\yy", @"C:\Users\yy\Desktop\",
                     @"\\server\share\Kitty Tools", "Kitty Tools", @"C:\Program Files",
                 })
        {
            Assert.IsTrue(SetupRules.IsForbiddenInstallDir(dir, Folders), dir);
        }

        foreach (var dir in new[]
                 {
                     @"C:\Users\yy\Desktop\Kitty Tools", @"C:\Users\yy\AppData\Local\Programs\Kitty Tools",
                     @"C:\Kitty Tools", @"D:\Kitty Tools", @"C:\Program Files Extra\Kitty Tools", @"C:\WindowsApps2\Kitty Tools",
                 })
        {
            Assert.IsFalse(SetupRules.IsForbiddenInstallDir(dir, Folders), dir);
        }
    }

    [TestMethod]
    public void WhyNotInstallDirExplains()
    {
        Assert.IsNull(SetupRules.WhyNotInstallDir(@"C:\Users\yy\AppData\Local\Programs\Kitty Tools", Folders));
        Assert.IsNotNull(SetupRules.WhyNotInstallDir(@"C:\Program Files\Kitty Tools", Folders));
        Assert.IsNotNull(SetupRules.WhyNotInstallDir(@"\\server\share\Kitty Tools", Folders));
        var deep = @"D:\" + string.Join('\\', Enumerable.Repeat("abcdefghij", 19)) + @"\Kitty Tools";
        Assert.IsTrue(deep.Length > SetupRules.MaxInstallPathLength);
        Assert.IsNotNull(SetupRules.WhyNotInstallDir(deep, Folders));
        var fits = @"D:\" + string.Join('\\', Enumerable.Repeat("abcdefghij", 16)) + @"\Kitty Tools";
        Assert.IsTrue(fits.Length <= SetupRules.MaxInstallPathLength);
        Assert.IsNull(SetupRules.WhyNotInstallDir(fits, Folders));
    }

    [TestMethod]
    public void VersionsThatNeedTheReinstallQuestion()
    {
        Assert.IsTrue(SetupRules.IsSameOrOlder("0.7.0", "0.7.0"));
        Assert.IsTrue(SetupRules.IsSameOrOlder("0.7.0", "0.10.0"));
        Assert.IsFalse(SetupRules.IsSameOrOlder("0.10.0", "0.9.1"));
        Assert.IsFalse(SetupRules.IsSameOrOlder("0.7.0", null));
        Assert.IsFalse(SetupRules.IsSameOrOlder("0.7.0", "坏的"));
    }

    [TestMethod]
    public void RemovesWholeFolderOnlyWhenEveryCheckPasses()
    {
        const string dir = @"C:\Users\yy\AppData\Local\Programs\Kitty Tools";
        var marker = Marker(dir);
        string[] present = ["KittyTools.exe", "Uninstall.exe", ".kitty-install", @"Microsoft.UI.Xaml.dll", @"zh-CN\a.mui", "KittyTools.dll.old"];

        var ok = SetupRules.PlanRemoval(dir, present, marker, Folders);
        Assert.IsTrue(ok.WholeDirectory);
        Assert.AreEqual(present.Length, ok.Files.Count);

        // 1. 没有 KittyTools.exe
        Assert.IsFalse(SetupRules.PlanRemoval(dir, present.Where(file => file != "KittyTools.exe").ToList(), marker, Folders).WholeDirectory);
        // 2. 没有标记 / 标记里记的是别处
        Assert.IsFalse(SetupRules.PlanRemoval(dir, present, null, Folders).WholeDirectory);
        Assert.IsFalse(SetupRules.PlanRemoval(dir, present, Marker(@"D:\Kitty Tools"), Folders).WholeDirectory);
        // 3. 文件夹名字不是 Kitty Tools
        const string renamed = @"C:\Users\yy\AppData\Local\Programs\Kitty";
        Assert.IsFalse(SetupRules.PlanRemoval(renamed, present, Marker(renamed), Folders).WholeDirectory);
        // 4. 在禁止名单里
        const string programFiles = @"C:\Program Files\Kitty Tools";
        Assert.IsFalse(SetupRules.PlanRemoval(programFiles, present, Marker(programFiles), Folders).WholeDirectory);
    }

    [TestMethod]
    public void UnknownFilesAreLeftAlone()
    {
        const string dir = @"D:\Apps\Kitty Tools";
        string[] present = ["KittyTools.exe", "Uninstall.exe", ".kitty-install", "Microsoft.UI.Xaml.dll", "我的笔记.txt", @"zh-CN\a.mui"];
        var plan = SetupRules.PlanRemoval(dir, present, Marker(dir), Folders);
        Assert.IsFalse(plan.WholeDirectory);
        CollectionAssert.AreEquivalent(
            new[] { "KittyTools.exe", "Uninstall.exe", ".kitty-install", "Microsoft.UI.Xaml.dll", @"zh-CN\a.mui" },
            plan.Files.ToArray());

        // 没有标记：只认 exe、卸载程序和 .old。
        var bare = SetupRules.PlanRemoval(dir, present, null, Folders);
        CollectionAssert.AreEquivalent(new[] { "KittyTools.exe", "Uninstall.exe", ".kitty-install" }, bare.Files.ToArray());
    }

    [TestMethod]
    public void MarkerRoundTrips()
    {
        var marker = new SetupMarker(@"D:\软件\Kitty Tools", "0.7.0", 1_761_500_000_000, ["KittyTools.exe", @"zh-CN\a.mui"]);
        var parsed = SetupRules.ParseMarker(SetupRules.WriteMarker(marker));
        Assert.IsNotNull(parsed);
        Assert.AreEqual(marker.Path, parsed.Path);
        Assert.AreEqual(marker.Version, parsed.Version);
        Assert.AreEqual(marker.InstalledAt, parsed.InstalledAt);
        CollectionAssert.AreEqual(marker.Files.ToArray(), parsed.Files.ToArray());

        var withoutFiles = SetupRules.ParseMarker("{\"path\":\"D:\\\\Kitty Tools\",\"version\":\"0.7.0\",\"installedAt\":1}");
        Assert.IsNotNull(withoutFiles);
        Assert.AreEqual(0, withoutFiles.Files.Count);
        Assert.IsNull(SetupRules.ParseMarker("not json"));
        Assert.IsNull(SetupRules.ParseMarker("{\"path\":\"\",\"version\":\"0.7.0\",\"installedAt\":1}"));
        Assert.IsNull(SetupRules.ParseMarker("{\"path\":\"D:\\\\x\",\"version\":\"0.7.0\",\"installedAt\":\"soon\"}"));
    }

    [TestMethod]
    public void UninstallValues()
    {
        var values = SetupRules.UninstallValues(@"D:\Apps\Kitty Tools\", "0.7.0", 51_234, new DateTime(2026, 10, 26))
            .ToDictionary(value => value.Name);
        Assert.AreEqual(12, values.Count);
        Assert.AreEqual("Kitty Tools", values["DisplayName"].Text);
        Assert.AreEqual("0.7.0", values["DisplayVersion"].Text);
        Assert.AreEqual("Kitty Tools", values["Publisher"].Text);
        Assert.AreEqual(@"D:\Apps\Kitty Tools\KittyTools.exe,0", values["DisplayIcon"].Text);
        Assert.AreEqual(@"D:\Apps\Kitty Tools", values["InstallLocation"].Text);
        Assert.AreEqual("\"D:\\Apps\\Kitty Tools\\Uninstall.exe\"", values["UninstallString"].Text);
        Assert.AreEqual("\"D:\\Apps\\Kitty Tools\\Uninstall.exe\" --quiet", values["QuietUninstallString"].Text);
        Assert.AreEqual(1, values["NoModify"].Number);
        Assert.AreEqual(1, values["NoRepair"].Number);
        Assert.AreEqual(51_234, values["EstimatedSize"].Number);
        Assert.AreEqual("20261026", values["InstallDate"].Text);
        Assert.AreEqual("https://github.com/YyAdnBug/kitty-tools", values["URLInfoAbout"].Text);
        Assert.IsNull(values["DisplayName"].Number);
        Assert.IsNull(values["NoModify"].Text);

        var huge = SetupRules.UninstallValues(@"D:\Kitty Tools", "0.7.0", long.MaxValue, DateTime.Today);
        Assert.AreEqual(int.MaxValue, huge.Single(value => value.Name == "EstimatedSize").Number);
    }

    [TestMethod]
    public void TestKeyRenamesEverything()
    {
        var real = SetupRules.NamesFor(null);
        Assert.AreEqual("KittyTools", real.UninstallKey);
        Assert.AreEqual("KittyTools", real.RunValue);
        Assert.AreEqual("Kitty Tools.lnk", real.ShortcutFile);
        Assert.AreEqual("KittyTools/", real.CredentialPrefix);
        Assert.AreEqual(@"Local\KittyTools", real.MutexName);
        Assert.AreEqual("KittyTools.Instance", real.PipeName);
        Assert.AreEqual("KittyTools", real.DataFolder);
        Assert.IsNull(real.ProbeProfile);
        Assert.AreEqual(real, SetupRules.NamesFor(string.Empty));

        // 和 App 的 KITTY_PROBE_PROFILE=e2e1 那一套同名（App/Paths.cs 的 Release 分支）。
        var test = SetupRules.NamesFor("e2e1");
        Assert.AreEqual("KittyTools.Test.e2e1", test.UninstallKey);
        Assert.AreEqual("KittyTools.Probe.e2e1", test.RunValue);
        Assert.AreEqual("Kitty Tools.Test.e2e1.lnk", test.ShortcutFile);
        Assert.AreEqual("KittyTools/.Probe.e2e1", test.CredentialPrefix);
        Assert.AreEqual(@"Local\KittyTools.Probe.e2e1", test.MutexName);
        Assert.AreEqual("KittyTools.Instance.Probe.e2e1", test.PipeName);
        Assert.AreEqual("KittyTools.Probe.e2e1", test.DataFolder);
        Assert.AreEqual("e2e1", test.ProbeProfile);
        Assert.AreNotEqual(real.LogFile, test.LogFile);

        foreach (var bad in new[] { "a b", @"..\x", "测试", new string('a', 33) })
        {
            Assert.ThrowsExactly<ArgumentException>(() => SetupRules.NamesFor(bad), bad);
        }
    }

    private static SetupMarker Marker(string dir)
        => new(dir, "0.7.0", 1, ["KittyTools.exe", "Microsoft.UI.Xaml.dll", @"zh-CN\a.mui"]);
}

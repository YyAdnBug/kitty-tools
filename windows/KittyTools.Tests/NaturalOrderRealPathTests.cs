// PLAN-v20 N1 N2：便签导入 Markdown 时的文件名自然顺序（mac localizedStandardCompare）、图片路径整条解析完再比（mac resolvingSymlinksInPath）。
using System.Diagnostics;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NaturalOrderRealPathTests
{
    [TestMethod]
    public void NumbersSortByValue()
    {
        // 中文和英文谁先由当前区域定，这里分开比
        var notes = new[] { "便签 10.md", "便签 2.md", "便签 1.md", "便签 01.md" }.OrderBy(name => name, NaturalOrder.Instance).ToArray();
        CollectionAssert.AreEqual(new[] { "便签 1.md", "便签 01.md", "便签 2.md", "便签 10.md" }, notes);
        var latin = new[] { "Note b.md", "note A.md", "x100", "x99", "x" }.OrderBy(name => name, NaturalOrder.Instance).ToArray();
        CollectionAssert.AreEqual(new[] { "note A.md", "Note b.md", "x", "x99", "x100" }, latin);
        Assert.IsTrue(NaturalOrder.Instance.Compare("a99999999999999999999b", "a100000000000000000000b") < 0, "很长的数字也按数值比");
        Assert.AreEqual(0, NaturalOrder.Instance.Compare("便签 2", "便签 2"));
    }

    [TestMethod]
    public void JunctionPointingOutsideIsNotInside()
    {
        var temp = Path.Combine(Path.GetTempPath(), "kitty-realpath-" + Guid.NewGuid().ToString("N"));
        var root = Path.Combine(temp, "import");
        var outside = Path.Combine(temp, "outside");
        Directory.CreateDirectory(Path.Combine(root, "images"));
        Directory.CreateDirectory(outside);
        File.WriteAllBytes(Path.Combine(root, "images", "ok.png"), new byte[] { 1 });
        File.WriteAllBytes(Path.Combine(outside, "secret.png"), new byte[] { 2 });
        try
        {
            // 目录联接不要管理员（符号链接要）
            using (var mklink = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{Path.Combine(root, "link")}\" \"{outside}\"")
                   {
                       UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                   })!)
            {
                mklink.WaitForExit();
            }

            Assert.IsTrue(Directory.Exists(Path.Combine(root, "link")), "联接没建成");
            Assert.IsTrue(RealPath.IsInside(Path.Combine(root, "images", "ok.png"), root));
            Assert.IsFalse(RealPath.IsInside(Path.Combine(root, "link", "secret.png"), root), "经过联接跑到外面的不算在里面");
            Assert.AreEqual(
                Path.GetFullPath(Path.Combine(outside, "secret.png")), RealPath.Resolve(Path.Combine(root, "link", "secret.png")),
                ignoreCase: true);
        }
        finally
        {
            // 先删联接本身（Directory.Delete 联接只删联接，不进去删外面的东西）
            if (Directory.Exists(Path.Combine(root, "link")))
            {
                Directory.Delete(Path.Combine(root, "link"));
            }

            Directory.Delete(temp, recursive: true);
        }
    }
}

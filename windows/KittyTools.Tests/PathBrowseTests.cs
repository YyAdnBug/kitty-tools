// PLAN-v26 L1：启动器路径模式的纯函数（PathBrowse）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PathBrowseTests
{
    private static string? Variable(string name) => name.Equals("USERPROFILE", StringComparison.OrdinalIgnoreCase) ? @"C:\Users\me" : null;

    private static PathBrowse.Parsed? Parse(string text) => PathBrowse.Parse(text, @"C:\Users\me", Variable);

    [TestMethod]
    public void RecognizesWindowsPrefixes()
    {
        Assert.AreEqual(new PathBrowse.Parsed(@"C:\Windows\", @"C:\Windows\", "sys"), Parse(@"C:\Windows\sys"));
        Assert.AreEqual(new PathBrowse.Parsed(@"d:\", @"d:\", string.Empty), Parse("d:/"), "斜杠也认");
        Assert.AreEqual(new PathBrowse.Parsed(@"~\Doc\", @"C:\Users\me\Doc\", "a"), Parse(@"~\Doc\a"));
        Assert.AreEqual(new PathBrowse.Parsed(@"%userprofile%\", @"C:\Users\me\", string.Empty), Parse(@"%userprofile%\"));
        Assert.AreEqual(@"\\nas\share\", Parse(@"\\nas\share\x")?.Folder);
        Assert.IsTrue(Parse(@"\\nas\share\x")!.Value.IsNetwork);
        Assert.AreEqual(@"C:\a\b\", Parse(@"C:\a\\b\")?.Folder, "连着的分隔符并成一个");
    }

    [TestMethod]
    public void NotPaths()
    {
        Assert.IsNull(Parse("windows"));
        Assert.IsNull(Parse("C:"), "只打盘符还不列");
        Assert.IsNull(Parse(@"%NOPE%\x"), "没有这个变量");
        Assert.IsNull(Parse(@"\\nas"), "只打了服务器名");
        Assert.IsNull(Parse(@"\\nas\share"), "共享名还没打完");
        Assert.IsNull(Parse("1/2"), "除法不是路径");
    }

    [TestMethod]
    public void FiltersFoldersFirstAndHidesHidden()
    {
        var entries = new[]
        {
            new PathBrowse.Entry("zeta.txt", false, false),
            new PathBrowse.Entry("Alpha", true, false),
            new PathBrowse.Entry("beta", true, false),
            new PathBrowse.Entry(".git", true, true),
            new PathBrowse.Entry("alphabet.md", false, false),
            new PathBrowse.Entry("desktop.ini", false, true),
        };
        CollectionAssert.AreEqual(new[] { "Alpha", "beta", "alphabet.md", "zeta.txt" },
            PathBrowse.Filter(entries, string.Empty).Select(entry => entry.Name).ToArray());
        CollectionAssert.AreEqual(new[] { "Alpha", "alphabet.md" }, PathBrowse.Filter(entries, "al").Select(entry => entry.Name).ToArray());
        CollectionAssert.AreEqual(new[] { "beta", "alphabet.md" }, PathBrowse.Filter(entries, "bet").Select(entry => entry.Name).ToArray(), "开头对上的和中间对上（至少两个字）的");
        Assert.AreEqual(0, PathBrowse.Filter(entries, "t").Count, "一个字只认开头");
        CollectionAssert.AreEqual(new[] { ".git" }, PathBrowse.Filter(entries, ".g").Select(entry => entry.Name).ToArray(), "打了点才列隐藏项");
        Assert.IsTrue(PathBrowse.IsHidden("desktop.ini", FileAttributes.Hidden | FileAttributes.System));
        Assert.IsTrue(PathBrowse.IsHidden(".vs", FileAttributes.Directory));
        Assert.IsFalse(PathBrowse.IsHidden("a", FileAttributes.Normal));
    }

    [TestMethod]
    public void CompletionKeepsTypedForm()
    {
        var parsed = Parse(@"~\Doc\a")!.Value;
        Assert.AreEqual(@"~\Doc\Apps\", PathBrowse.Completion(parsed, new PathBrowse.Entry("Apps", true, false)));
        Assert.AreEqual(@"~\Doc\a.txt", PathBrowse.Completion(parsed, new PathBrowse.Entry("a.txt", false, false)));
    }

    [TestMethod]
    public void PowerShellQuoting()
    {
        Assert.AreEqual(@"'C:\Program Files\a'", PathBrowse.PowerShellQuoted(@"C:\Program Files\a"));
        Assert.AreEqual(@"'C:\it''s $HOME`x'", PathBrowse.PowerShellQuoted(@"C:\it's $HOME`x"));
    }

    [TestMethod]
    public void UpStopsAtRoot()
    {
        Assert.AreEqual(@"C:\Windows\", PathBrowse.Up(@"C:\Windows\sys"), "先去掉没打完的");
        Assert.AreEqual(@"C:\", PathBrowse.Up(@"C:\Windows\"));
        Assert.IsNull(PathBrowse.Up(@"C:\"));
        Assert.AreEqual(@"~\", PathBrowse.Up(@"~\Documents\"));
        Assert.IsNull(PathBrowse.Up(@"~\"));
        Assert.AreEqual(@"\\nas\share\", PathBrowse.Up(@"\\nas\share\dir\"));
        Assert.IsNull(PathBrowse.Up(@"\\nas\share\"));
        Assert.IsNull(PathBrowse.Up("hello"));
    }
}

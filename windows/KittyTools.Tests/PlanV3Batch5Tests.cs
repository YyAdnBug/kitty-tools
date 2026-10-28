// 第三版第 5 批的纯函数单测：启动器的命令前缀、文件搜索排序、Chromium 书签、netstat 的监听行。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherCommandTests
{
    [TestMethod]
    public void ClassifiesModes()
    {
        Assert.AreEqual(LauncherMode.FileSearch, LauncherCommands.Classify(" report").Mode);
        Assert.AreEqual("report", LauncherCommands.Classify(" report").Query);
        Assert.AreEqual(LauncherMode.FileSearch, LauncherCommands.Classify("open report.pdf").Mode);
        Assert.AreEqual("report.pdf", LauncherCommands.Classify("open report.pdf").Query);
        // PLAN-v9-launcher：find 和 open 分开（find 的 Enter 是在资源管理器中显示）。
        Assert.AreEqual(LauncherMode.FileFind, LauncherCommands.Classify("FIND report").Mode);
        Assert.AreEqual(LauncherMode.Kill, LauncherCommands.Classify("kill code").Mode);
        Assert.AreEqual("code", LauncherCommands.Classify("kill code").Query);
        Assert.AreEqual(LauncherMode.Port, LauncherCommands.Classify("port 443").Mode);
        Assert.AreEqual("443", LauncherCommands.Classify("port 443").Query);
        Assert.AreEqual(LauncherMode.Normal, LauncherCommands.Classify("chrome").Mode);
        Assert.AreEqual(LauncherMode.Normal, LauncherCommands.Classify(" ").Mode); // 只有空格 = 普通
    }

    [TestMethod]
    public void ScoresFileNames()
    {
        var tokens = new[] { "re", "port" };
        var starts = LauncherCommands.ScoreFileName("report-2026.pdf", tokens);
        var middle = LauncherCommands.ScoreFileName("my-report.pdf", tokens);
        var missing = LauncherCommands.ScoreFileName("summary.pdf", tokens);
        Assert.IsTrue(starts > middle);
        Assert.AreEqual(int.MinValue, missing);
        Assert.IsTrue(LauncherCommands.ScoreFileName("report.pdf", new[] { "report" }) >
                      LauncherCommands.ScoreFileName("a-very-long-report-name.pdf", new[] { "report" }));
    }
}

[TestClass]
public sealed class BookmarkParsingTests
{
    [TestMethod]
    public void WalksChromiumRoots()
    {
        var json = """
            {
              "roots": {
                "bookmark_bar": {
                  "children": [
                    { "type": "url", "name": "GitHub", "url": "https://github.com/" },
                    { "type": "folder", "name": "工作", "children": [
                        { "type": "url", "name": "Docs", "url": "https://example.com/docs" }
                    ]}
                  ]
                },
                "other": { "children": [ { "type": "url", "name": "Local", "url": "file:///C:/x" } ] }
              }
            }
            """;
        var items = ChromiumBookmarks.Parse(json, "Chrome/Default");
        Assert.AreEqual(2, items.Count);
        Assert.AreEqual("GitHub", items[0].Title);
        Assert.AreEqual("https://github.com/", items[0].Url);
        Assert.AreEqual("Chrome/Default", items[0].Source);
        Assert.AreEqual("https://example.com/docs", items[1].Url);
        Assert.AreEqual(0, ChromiumBookmarks.Parse("not json", "x").Count);
        Assert.AreEqual(0, ChromiumBookmarks.Parse("{}", "x").Count);
    }
}

[TestClass]
public sealed class NetstatParsingTests
{
    [TestMethod]
    public void ParsesListeningTcpAndUdp()
    {
        var output = """
            活动连接

              协议  本地地址          外部地址        状态           PID
              TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1200
              TCP    127.0.0.1:5432         0.0.0.0:0              LISTENING       4321
              TCP    127.0.0.1:9000         127.0.0.1:55000        ESTABLISHED     9999
              UDP    0.0.0.0:5353           *:*                                    2000
              UDP    [::]:5353              *:*                                    2000
            """;
        var rows = NetstatOutput.Parse(output);
        Assert.AreEqual(4, rows.Count);
        Assert.IsTrue(rows.Any(row => row is { Protocol: "TCP", Port: 135, Pid: 1200 }));
        Assert.IsTrue(rows.Any(row => row is { Port: 5432, Pid: 4321 }));
        Assert.IsFalse(rows.Any(row => row.Port == 9000)); // 不是监听
        Assert.IsTrue(rows.Any(row => row is { Protocol: "UDP", Port: 5353 }));
        Assert.AreEqual(135, rows[0].Port); // 按端口排
        Assert.AreEqual(0, NetstatOutput.Parse(string.Empty).Count);
    }
}

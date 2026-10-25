// REVIEW R1 的单测：发布列表和下载地址的白名单、伪装主机、大小写、端口、账号密码、
// 以及「测试用发布列表只在 Debug 或 --update-test 下认」。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class UpdateTrustTests
{
    [TestMethod]
    public void FeedOnlyFromGithubApi()
    {
        Assert.IsTrue(UpdateTrust.IsAllowedFeedUrl(UpdateTrust.FeedUrl));
        // 正式用的地址带 ?per_page=20。
        Assert.IsTrue(UpdateTrust.IsAllowedFeedUrl(UpdateTrust.FeedUrl + "?per_page=20"));
        Assert.IsTrue(UpdateTrust.IsAllowedFeedUrl(UpdateTrust.FeedUrl + "/"));
        // 大小写（主机和路径都不敏感）。
        Assert.IsTrue(UpdateTrust.IsAllowedFeedUrl("HTTPS://API.GITHUB.COM/repos/yyadnbug/KITTY-TOOLS/releases"));

        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl(null));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl(string.Empty));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("http://api.github.com/repos/YyAdnBug/kitty-tools/releases"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("file:///C:/feed.json"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl(@"C:\feed.json"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("https://api.github.com/repos/YyAdnBug/other/releases"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("https://api.github.com/repos/YyAdnBug/kitty-tools/releases/1/assets"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("https://api.github.com.cn/repos/YyAdnBug/kitty-tools/releases"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("https://api.github.com:8443/repos/YyAdnBug/kitty-tools/releases"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("https://user:pass@api.github.com/repos/YyAdnBug/kitty-tools/releases"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl(" https://api.github.com/repos/YyAdnBug/kitty-tools/releases"));
        Assert.IsFalse(UpdateTrust.IsAllowedFeedUrl("https://api.github.com/repos/YyAdnBug/kitty-tools/releases\u0000"));
    }

    [TestMethod]
    public void DownloadOnlyFromGithubHosts()
    {
        var good = new[]
        {
            "https://github.com/YyAdnBug/kitty-tools/releases/download/windows-v0.1.1/KittyTools-0.1.1-windows-x64.zip",
            "https://github.com/YyAdnBug/kitty-tools/releases/download/windows-v0.1.1/KittyTools-0.1.1-windows-x64.zip.sha256",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/123/abc?X-Amz-Signature=deadbeef",
            "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc",
            // 大小写。
            "HTTPS://GITHUB.COM/yyadnbug/kitty-tools/RELEASES/download/windows-v0.1.1/KittyTools.zip",
            // 显式 443 也认。
            "https://github.com:443/YyAdnBug/kitty-tools/releases/download/x/y.zip",
        };
        foreach (var url in good)
        {
            Assert.IsTrue(UpdateTrust.IsAllowedDownloadUrl(url), url);
        }

        var bad = new[]
        {
            null,
            string.Empty,
            "http://github.com/YyAdnBug/kitty-tools/releases/download/x/y.zip",
            "ftp://github.com/YyAdnBug/kitty-tools/releases/download/x/y.zip",
            "file:///C:/KittyTools.zip",
            @"C:\KittyTools.zip",
            "https://github.com.evil.com/YyAdnBug/kitty-tools/releases/download/x/y.zip",
            "https://evilgithub.com/YyAdnBug/kitty-tools/releases/download/x/y.zip",
            "https://github.com/YyAdnBug/kitty-tools/releases/tag/windows-v0.1.1",
            "https://github.com/OtherUser/kitty-tools/releases/download/x/y.zip",
            "https://raw.githubusercontent.com/YyAdnBug/kitty-tools/main/y.zip",
            "https://api.github.com/repos/YyAdnBug/kitty-tools/releases",
            "https://github.com:8443/YyAdnBug/kitty-tools/releases/download/x/y.zip",
            "https://user:pass@github.com/YyAdnBug/kitty-tools/releases/download/x/y.zip",
            "https://objects.githubusercontent.com.evil.com/x/y.zip",
            "https://github.com/\u0000x",
            "//github.com/YyAdnBug/kitty-tools/releases/download/x/y.zip",
        };
        foreach (var url in bad)
        {
            Assert.IsFalse(UpdateTrust.IsAllowedDownloadUrl(url), url ?? "(null)");
        }
    }

    [TestMethod]
    public void TestSourcesOnlyInDebugOrWithFlag()
    {
        Assert.IsTrue(UpdateTrust.AllowTestSources(debugBuild: true, Array.Empty<string>()));
        Assert.IsTrue(UpdateTrust.AllowTestSources(debugBuild: false, new[] { "--update-test" }));
        Assert.IsTrue(UpdateTrust.AllowTestSources(debugBuild: false, new[] { "--updated", "--UPDATE-TEST" }));
        Assert.IsFalse(UpdateTrust.AllowTestSources(debugBuild: false, Array.Empty<string>()));
        Assert.IsFalse(UpdateTrust.AllowTestSources(debugBuild: false, new[] { "--update-testing" }));
    }

    [TestMethod]
    public void TestSourceDetection()
    {
        Assert.IsFalse(UpdateTrust.IsTestSource("https://github.com/YyAdnBug/kitty-tools/releases/download/x/y.zip"));
        Assert.IsTrue(UpdateTrust.IsTestSource("http://127.0.0.1:8080/releases.json"));
        Assert.IsTrue(UpdateTrust.IsTestSource("file:///C:/releases.json"));
        Assert.IsTrue(UpdateTrust.IsTestSource(null));
    }
}

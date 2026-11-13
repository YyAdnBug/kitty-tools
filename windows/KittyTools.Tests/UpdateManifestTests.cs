// 更新清单 windows-update.json（PLAN-v18 L12，照 mac UpdaterTests 里清单那几条）：解析出这个架构的 zip、坏清单当读不到、
// 地址过不了白名单不认、403 / 429 认成限流；build-release.ps1 写的文件名、键和 App 读的一样。
using System.Runtime.CompilerServices;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class UpdateManifestTests
{
    private const string Hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string Base = "https://github.com/YyAdnBug/kitty-tools/releases";

    private static string Manifest(string version = "0.2.0", string? x64Url = null, string sha = Hash, string page = Base + "/tag/windows-v0.2.0", long size = 1000)
        => $$"""
            {
              "version": "{{version}}",
              "page": "{{page}}",
              "x64": { "url": "{{x64Url ?? $"{Base}/download/windows-v{version}/KittyTools-{version}-windows-x64.zip"}}", "sha256": "{{sha}}", "size": {{size}} },
              "arm64": { "url": "{{Base}}/download/windows-v{{version}}/KittyTools-{{version}}-windows-arm64.zip", "sha256": "{{Hash}}", "size": 900 }
            }
            """;

    [TestMethod]
    public void Parse_TakesThisArchitecture()
    {
        var offer = UpdateManifest.Parse(Manifest(), "x64", UpdateTrust.IsAllowedDownloadUrl);
        Assert.IsNotNull(offer);
        Assert.AreEqual("0.2.0", offer.Version);
        Assert.AreEqual(Base + "/tag/windows-v0.2.0", offer.Page);
        Assert.AreEqual($"{Base}/download/windows-v0.2.0/KittyTools-0.2.0-windows-x64.zip", offer.ZipUrl);
        Assert.AreEqual(offer.ZipUrl + ".sha256", offer.HashUrl, "下载照旧核 zip 旁边的 .sha256");
        Assert.AreEqual("KittyTools-0.2.0-windows-x64.zip", offer.AssetName);
        Assert.AreEqual(1000, offer.Size);
        var arm = UpdateManifest.Parse(Manifest(), "arm64", UpdateTrust.IsAllowedDownloadUrl);
        Assert.AreEqual("KittyTools-0.2.0-windows-arm64.zip", arm?.AssetName);
        // 大写的哈希照认（统一成小写）
        Assert.AreEqual(Hash, UpdateManifest.Parse(Manifest(sha: Hash.ToUpperInvariant()), "x64", _ => true)?.Sha256);
    }

    [TestMethod]
    public void Parse_BadManifestIsUnreadable()
    {
        static UpdateOffer? Parse(string json, string arch = "x64") => UpdateManifest.Parse(json, arch, UpdateTrust.IsAllowedDownloadUrl);
        Assert.IsNull(Parse("not json"));
        Assert.IsNull(Parse("[]"));
        Assert.IsNull(Parse("{}"));
        Assert.IsNull(Parse(Manifest(version: "0.2.0-beta")), "版本号只有数字和点");
        Assert.IsNull(Parse(Manifest(sha: "abc")), "sha256 不是 64 位十六进制");
        Assert.IsNull(Parse(Manifest(page: "http://github.com/x")), "发布页要 https");
        Assert.IsNull(Parse(Manifest(size: 0)));
        Assert.IsNull(Parse(Manifest(x64Url: $"{Base}/download/windows-v0.2.0/KittyTools-0.2.0-windows-arm64.zip")), "名字和架构对不上");
        Assert.IsNull(Parse(Manifest(x64Url: "https://evil.example/KittyTools-0.2.0-windows-x64.zip")), "过不了白名单");
        Assert.IsNull(Parse(Manifest(x64Url: $"http://github.com/YyAdnBug/kitty-tools/releases/download/windows-v0.2.0/KittyTools-0.2.0-windows-x64.zip")));
        Assert.IsNull(Parse(Manifest(), "riscv"), "这个架构没有");
        Assert.IsNull(Parse("""{"version":"0.2.0","page":"https://github.com/x","x64":{"url":5}}"""));
    }

    [TestMethod]
    public void ManifestUrlIsAnAllowedDownload()
    {
        Assert.IsTrue(UpdateTrust.IsAllowedDownloadUrl(UpdateManifest.Url), "白名单本来就认 releases/download 下的地址");
        StringAssert.EndsWith(UpdateManifest.Url, "/releases/download/windows-update/windows-update.json");
    }

    [TestMethod]
    public void RateLimitStatuses()
    {
        Assert.IsTrue(UpdateManifest.IsRateLimited(403));
        Assert.IsTrue(UpdateManifest.IsRateLimited(429));
        Assert.IsFalse(UpdateManifest.IsRateLimited(404));
        Assert.IsFalse(UpdateManifest.IsRateLimited(500));
        StringAssert.Contains(UpdateManifest.RateLimitedText, "限流");
    }

    [TestMethod]
    public void BuildScriptWritesTheSameFile()
    {
        // 同 mac：打包脚本和 App 认同一个文件名、同样几个键。
        var script = File.ReadAllText(Path.Combine(WindowsRoot(), "build-release.ps1"));
        StringAssert.Contains(script, "'" + UpdateManifest.FileName + "'");
        StringAssert.Contains(script, "releases/download/" + UpdateManifest.ReleaseTag + "/" + UpdateManifest.FileName);
        foreach (var key in new[] { "version = $version", "page = ", "url = ", "sha256 = $hash", "size = " })
        {
            StringAssert.Contains(script, key);
        }
    }

    private static string WindowsRoot([CallerFilePath] string path = "")
        => Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, ".."));
}

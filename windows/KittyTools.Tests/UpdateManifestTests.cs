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

    // GitCode 那份清单的签名（PLAN-gitcode）：mac 的 sign-manifest.swift selftest 用一把临时钥匙（CryptoKit P-256）签的测试向量，
    // 在 Mac 上已经用 openssl 交叉核对过；这里核 .NET 的 ECDsa 认 CryptoKit 写的 DER 签名和 SPKI 公钥。
    private const string TestKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/CcmSn5GJI/lt+unzy63/pJvmpUULU0ZoVAzBmsQmm1VgClG193+88npTEb28CapygSKBo0Dp6NHu+G1t0jpXw==";
    private const string TestSample = "eyJ2ZXJzaW9uIjoiMC4zLjAiLCJwYWdlIjoiaHR0cHM6Ly9naXRjb2RlLmNvbS95eWFuZGJ1Zy9raXR0eS10b29scy9yZWxlYXNlcy93aW5kb3dzLXYwLjMuMCJ9";
    private const string TestSignature = "MEQCIBiMjQtYTEcsd0wNf60arM7MSP/pkDt3AxmM/5aZ1nzQAiBYDxIdNNixFz9dTzo9kM7p2L/YkTVDAKK6ZqaoWprV+w==";

    [TestMethod]
    public void VerifySignature_OnlyTheSignedBytes()
    {
        var sample = Convert.FromBase64String(TestSample);
        Assert.IsTrue(UpdateManifest.VerifySignature(sample, TestSignature, TestKey));
        Assert.IsTrue(UpdateManifest.VerifySignature(sample, TestSignature + "\n", TestKey), "sig 文件末尾的换行不算");
        var tampered = (byte[])sample.Clone();
        tampered[^2] ^= 1;
        Assert.IsFalse(UpdateManifest.VerifySignature(tampered, TestSignature, TestKey), "改了一个字节");
        Assert.IsFalse(UpdateManifest.VerifySignature(sample, null, TestKey));
        Assert.IsFalse(UpdateManifest.VerifySignature(sample, "不是 base64", TestKey));
        Assert.IsFalse(UpdateManifest.VerifySignature(sample, Convert.ToBase64String(new byte[70]), TestKey));
        Assert.IsFalse(UpdateManifest.VerifySignature(sample, TestSignature, ""), "没填公钥 = 一律不认");
        using var other = System.Security.Cryptography.ECDsa.Create(System.Security.Cryptography.ECCurve.NamedCurves.nistP256);
        Assert.IsFalse(
            UpdateManifest.VerifySignature(sample, TestSignature, Convert.ToBase64String(other.ExportSubjectPublicKeyInfo())),
            "别的钥匙");
        // 公钥末尾改一个字符：点不在曲线上，Windows 的 CNG 报 PlatformNotSupportedException（不是 CryptographicException）
        var broken = TestKey[..^4] + (TestKey[^4] == 'A' ? 'B' : 'A') + TestKey[^3..];
        Assert.IsFalse(UpdateManifest.VerifySignature(sample, TestSignature, broken), "公钥坏了");
    }

    [TestMethod]
    public void Parse_GitCodeManifest()
    {
        // publish-gitcode.sh 改写过地址的那份：zip 在 GitCode 上，白名单认
        const string gitcode = "https://gitcode.com/yyandbug/kitty-tools/releases";
        var json = Manifest(x64Url: $"{gitcode}/download/windows-v0.2.0/KittyTools-0.2.0-windows-x64.zip", page: gitcode + "/windows-v0.2.0");
        var offer = UpdateManifest.Parse(json, "x64", UpdateTrust.IsAllowedDownloadUrl);
        Assert.IsNotNull(offer);
        Assert.AreEqual(Hash, offer.Sha256);
        Assert.IsTrue(UpdateTrust.IsAllowedDownloadUrl(UpdateManifest.GitCodeUrl));
        Assert.IsTrue(UpdateTrust.IsAllowedDownloadUrl(UpdateManifest.GitCodeUrl + UpdateManifest.SignatureSuffix));
        Assert.AreEqual(UpdateManifest.GitCodeUrl, UpdateTrust.Mirror(UpdateManifest.Url));
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

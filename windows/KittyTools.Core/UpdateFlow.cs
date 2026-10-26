// 自动更新整条流水线（下载 → 校验 → 解压 → 找入口 → 比版本 → 覆盖），配单测和
// `--update-e2e` 自检。AutoUpdater 只负责提示、进度和重启，实际步骤都在这里，测试可以
// 用本地 file:// 传输 + 真 zip + 临时安装目录把成功和两条失败路（sha256 错、替换被占用回滚）
// 完整跑一遍，不用再照 HANDTEST 手工搭目录。
//
// 约定：
// - 失败时把「走到哪一步」一起返回，调用方据此选提示文字；
// - 安装目录没有写权限、下载失败、解压失败、没 exe、版本对不上都算失败，旧版本一律不动；
// - 覆盖失败由 UpdateInstaller 自己回滚，这里只把失败透出来；
// - 下载的 zip 无论成败都在 finally 删掉，staging 留给调用方清理。
using System.IO.Compression;

namespace KittyTools.Core;

public sealed record UpdatePlan(string Version, string ZipUrl, string? HashUrl, string AssetName);

public enum UpdateStep
{
    Download,
    Hash,
    Extract,
    Entry,
    Version,
    Install,
}

public sealed record UpdateFlowResult(
    bool Ok,
    UpdateStep Step,
    string? Error,
    IReadOnlyList<string> Installed,
    string? EntryDirectory)
{
    public static UpdateFlowResult Failed(UpdateStep step, string error)
        => new(false, step, error, Array.Empty<string>(), null);
}

public static class UpdateFlow
{
    /// <summary>
    /// 跑完整条流水线。传输用调用方给的两个函数（正常是 UpdateHttp，测试可以给假的），
    /// 版本号从 exe 的 FileVersionInfo 读，读不到就返回 <paramref name="readVersion"/> 的结果。
    /// </summary>
    public static async Task<UpdateFlowResult> RunAsync(
        UpdatePlan plan,
        string downloadDirectory,
        string stagingDirectory,
        string installDirectory,
        Func<string, string, Action<long, long?>?, CancellationToken, Task> downloadAsync,
        Func<string, CancellationToken, Task<string>> getTextAsync,
        Func<string, Version?> readVersion,
        Action<long, long?>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(installDirectory))
        {
            return UpdateFlowResult.Failed(UpdateStep.Install, "安装目录不存在");
        }

        Directory.CreateDirectory(downloadDirectory);
        Directory.CreateDirectory(stagingDirectory);
        var zip = Path.Combine(downloadDirectory, plan.AssetName);
        var step = UpdateStep.Download;
        try
        {
            await downloadAsync(plan.ZipUrl, zip, progress, cancellationToken);

            step = UpdateStep.Hash;
            if (string.IsNullOrWhiteSpace(plan.HashUrl))
            {
                return UpdateFlowResult.Failed(UpdateStep.Hash, "这个版本没有附 .sha256");
            }

            var hashText = await getTextAsync(plan.HashUrl, cancellationToken);
            var expected = UpdateHash.ExpectedFor(hashText, Path.GetFileName(zip));
            if (expected is null || !UpdateHash.FileMatches(zip, expected))
            {
                return UpdateFlowResult.Failed(UpdateStep.Hash, "下载的更新包校验对不上");
            }

            step = UpdateStep.Extract;
            ZipFile.ExtractToDirectory(zip, stagingDirectory, overwriteFiles: true);

            step = UpdateStep.Entry;
            var entry = UpdateInstaller.FindEntryDirectory(stagingDirectory, "KittyTools.exe");
            if (entry is null)
            {
                return UpdateFlowResult.Failed(UpdateStep.Entry, "更新包里没有 KittyTools.exe");
            }

            step = UpdateStep.Version;
            var stagedVersion = readVersion(Path.Combine(entry, "KittyTools.exe"));
            if (stagedVersion is null || stagedVersion.ToString(3) != plan.Version)
            {
                return UpdateFlowResult.Failed(
                    UpdateStep.Version,
                    $"更新包的版本对不上（期望 {plan.Version}，实际 {stagedVersion?.ToString(3) ?? "?"}）");
            }

            step = UpdateStep.Install;
            var result = UpdateInstaller.Install(entry, installDirectory);
            return result.Ok
                ? new UpdateFlowResult(true, UpdateStep.Install, null, result.Installed, entry)
                : UpdateFlowResult.Failed(UpdateStep.Install, result.Error ?? "覆盖安装失败");
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return UpdateFlowResult.Failed(step, $"{ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            UpdateDownload.TryDelete(zip);
            UpdateDownload.TryDelete(UpdateDownload.PartialPath(zip));
        }
    }

    /// <summary>从 exe 的版本资源读版本号（ProductVersion 常带 +hash，取前面能解析的部分）。</summary>
    public static Version? ReadVersion(string exePath)
    {
        try
        {
            var info = System.Diagnostics.FileVersionInfo.GetVersionInfo(exePath);
            var text = info.ProductVersion ?? info.FileVersion;
            if (string.IsNullOrWhiteSpace(text))
            {
                return null;
            }

            var cut = text.IndexOfAny(new[] { '+', '-', ' ' });
            return Version.TryParse(cut < 0 ? text : text[..cut], out var version) ? version : null;
        }
        catch
        {
            return null;
        }
    }
}

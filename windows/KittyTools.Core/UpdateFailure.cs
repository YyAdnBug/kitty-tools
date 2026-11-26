// 自动更新失败时怎么说（PLAN-v26 G3，同 mac 0.10.1 92a057af）：只有网络问题给「重试」；磁盘满单独说；没权限、别的原因直接给「到发布页下载」
// 和原因（重试也还是一样失败）。按异常的类型名和 HResult 分，纯函数。
namespace KittyTools.Core;

public static class UpdateFailure
{
    public enum Kind
    {
        Network,
        DiskFull,
        Permission,
        Other,
    }

    /// <summary>ERROR_DISK_FULL、ERROR_HANDLE_DISK_FULL（IOException 的 HResult）。</summary>
    private static readonly int[] DiskFull = { unchecked((int)0x80070070), unchecked((int)0x80070027) };

    /// <param name="type">异常的类型名（GetType().Name）；里头套着的看最里面那个。</param>
    public static Kind Classify(string type, int hresult)
    {
        if (DiskFull.Contains(hresult))
        {
            return Kind.DiskFull;
        }

        return type switch
        {
            "HttpRequestException" or "SocketException" or "TimeoutException" or "TaskCanceledException" or "HttpIOException" => Kind.Network,
            "UnauthorizedAccessException" => Kind.Permission,
            _ when hresult == unchecked((int)0x80070005) => Kind.Permission,
            _ => Kind.Other,
        };
    }

    /// <summary>提示的标题和说明。</summary>
    public static (string Title, string Detail) Message(Kind kind) => kind switch
    {
        Kind.Network => ("更新没下载完", "网络断了或者太慢，旧版本还能正常用；点「重试」再下一次"),
        Kind.DiskFull => ("磁盘空间不够，没能更新", "腾出一些空间再更新；旧版本还能正常用"),
        Kind.Permission => ("没有权限替换程序文件", "自动更新改不了安装目录里的文件，到发布页下载新版本装上"),
        _ => ("更新失败", "旧版本还能正常用；可以到发布页下载新版本装上"),
    };
}

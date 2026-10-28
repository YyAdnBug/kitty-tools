// 启动器「ip」的读网卡和联网查（照 mac Launcher/IPAddresses.swift；拼行的纯函数在 Core 的 LauncherIp）：
// 本机：System.Net.NetworkInformation 列开着的网卡（回环不列），每块的 IPv4；默认路由走的那块（GetBestInterface 问到 8.8.8.8
// 走哪块）排第一。VPN：PPP / 隧道类型的网卡，或说明里写着 VPN / WireGuard / TAP 的；代理 TUN 的 198.18 假地址在 Core 里滤掉。
// 外网：问 myip.ipip.net 和 api.ipify.org（不带 Cookie、5 秒没回算没查到、回的不是一个 IPv4 也算没查到）。
// 日志里不写地址（AGENTS 红线：日志不出现内容）。
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static partial class IpAddresses
{
    private static readonly HttpClient Http = new(new SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = false })
    {
        Timeout = TimeSpan.FromMilliseconds(LauncherIp.LookupTimeoutMs),
    };

    /// <summary>本机这一刻的几行（列网卡，几毫秒到几十毫秒）。</summary>
    public static List<LauncherItem> LocalItems()
    {
        var addresses = new List<LocalAddress>();
        string? primary = null;
        try
        {
            var best = GetBestInterface(0x08080808, out var index) == 0 ? (int?)index : null;
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                var properties = adapter.GetIPProperties();
                try
                {
                    if (best is { } bestIndex && properties.GetIPv4Properties()?.Index == bestIndex)
                    {
                        primary = adapter.Id;
                    }
                }
                catch (NetworkInformationException)
                {
                    // 这块网卡没开 IPv4：下面也不会有它的地址。
                    continue;
                }

                var vpn = adapter.NetworkInterfaceType is NetworkInterfaceType.Ppp or NetworkInterfaceType.Tunnel ||
                          new[] { "VPN", "WireGuard", "TAP-" }.Any(word =>
                              adapter.Description.Contains(word, StringComparison.OrdinalIgnoreCase));
                foreach (var unicast in properties.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork)
                    {
                        continue;
                    }

                    var address = unicast.Address.ToString();
                    if (LauncherIp.IsUsable(address))
                    {
                        addresses.Add(new LocalAddress(adapter.Id, adapter.Name, address, vpn));
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.ip-local-failed {ex.GetType().Name}");
        }

        return LauncherIp.LocalItems(addresses, primary);
    }

    /// <summary>问一家：5 秒没回、不是 200、回的不是一个 IPv4 都算没查到（null）。</summary>
    public static async Task<string?> LookUpAsync(IpService service, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await Http.GetAsync(LauncherIp.Url(service), cancellationToken).ConfigureAwait(false);
            if (response.StatusCode != System.Net.HttpStatusCode.OK)
            {
                return null;
            }

            var text = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            return LauncherIp.AddressIn(text.Length > 64 ? string.Empty : text);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            Log.Info($"launcher.ip-lookup-failed service={service} {ex.GetType().Name}");
            return null;
        }
    }

    [LibraryImport("iphlpapi.dll")]
    private static partial uint GetBestInterface(uint destination, out uint index);
}

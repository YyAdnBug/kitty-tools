// 端口表的纯函数（R18）：MIB 的端口是网络字节序，IPv4 地址按字节小端存。
namespace KittyTools.Core;

public static class PortMath
{
    public static int PortOf(uint port) => (int)(((port & 0xFF) << 8) | ((port >> 8) & 0xFF));

    public static string FormatV4(uint address)
        => $"{address & 0xFF}.{(address >> 8) & 0xFF}.{(address >> 16) & 0xFF}.{(address >> 24) & 0xFF}";
}

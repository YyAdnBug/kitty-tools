// 端口列表（REVIEW R18）：用 GetExtendedTcpTable / GetExtendedUdpTable 拿监听表，不再解析 netstat 的输出。
// 只取 LISTEN 的 TCP 和全部 UDP（UDP 没有监听状态）；IPv4、IPv6 各读一次。
using System.Net;
using System.Runtime.InteropServices;
using KittyTools.Core;

namespace KittyTools;

public static unsafe class PortTable
{
    private const int AfInet = 2;
    private const int AfInet6 = 23;
    private const int TcpTableOwnerPidListener = 3;
    private const int UdpTableOwnerPid = 1;
    private const uint ErrorInsufficientBuffer = 122;

    public static List<PortRow> Read()
    {
        var rows = new List<PortRow>();
        ReadTcp(rows, AfInet);
        ReadTcp6(rows);
        ReadUdp(rows, AfInet);
        ReadUdp6(rows);
        rows.Sort((left, right) => left.Port.CompareTo(right.Port));
        return rows;
    }

    private static unsafe void ReadTcp(List<PortRow> rows, int family)
    {
        var size = 0;
        var result = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, TcpTableOwnerPidListener, 0);
        if (result != ErrorInsufficientBuffer || size <= 4)
        {
            return;
        }

        var buffer = new byte[size];
        fixed (byte* pointer = buffer)
        {
            result = GetExtendedTcpTable((IntPtr)pointer, ref size, false, family, TcpTableOwnerPidListener, 0);
            if (result != 0)
            {
                return;
            }

            var count = *(uint*)pointer;
            var rowSize = Marshal.SizeOf<Tcp4Row>();
            var offset = 4;
            for (var index = 0; index < count && offset + rowSize <= size; index++, offset += rowSize)
            {
                var row = *(Tcp4Row*)(pointer + offset);
                rows.Add(new PortRow("TCP", PortMath.FormatV4(row.LocalAddress), PortMath.PortOf(row.LocalPort), (int)row.Pid));
            }
        }
    }

    private static unsafe void ReadTcp6(List<PortRow> rows)
    {
        var size = 0;
        var result = GetExtendedTcpTable(IntPtr.Zero, ref size, false, AfInet6, TcpTableOwnerPidListener, 0);
        if (result != ErrorInsufficientBuffer || size <= 4)
        {
            return;
        }

        var buffer = new byte[size];
        fixed (byte* pointer = buffer)
        {
            result = GetExtendedTcpTable((IntPtr)pointer, ref size, false, AfInet6, TcpTableOwnerPidListener, 0);
            if (result != 0)
            {
                return;
            }

            var count = *(uint*)pointer;
            var rowSize = sizeof(Tcp6Row);
            var offset = 4;
            for (var index = 0; index < count && offset + rowSize <= size; index++, offset += rowSize)
            {
                var row = *(Tcp6Row*)(pointer + offset);
                rows.Add(new PortRow("TCP", FormatV6(row.LocalAddress), PortMath.PortOf(row.LocalPort), (int)row.Pid));
            }
        }
    }

    private static unsafe void ReadUdp(List<PortRow> rows, int family)
    {
        var size = 0;
        var result = GetExtendedUdpTable(IntPtr.Zero, ref size, false, family, UdpTableOwnerPid, 0);
        if (result != ErrorInsufficientBuffer || size <= 4)
        {
            return;
        }

        var buffer = new byte[size];
        fixed (byte* pointer = buffer)
        {
            result = GetExtendedUdpTable((IntPtr)pointer, ref size, false, family, UdpTableOwnerPid, 0);
            if (result != 0)
            {
                return;
            }

            var count = *(uint*)pointer;
            var rowSize = Marshal.SizeOf<Udp4Row>();
            var offset = 4;
            for (var index = 0; index < count && offset + rowSize <= size; index++, offset += rowSize)
            {
                var row = *(Udp4Row*)(pointer + offset);
                rows.Add(new PortRow("UDP", PortMath.FormatV4(row.LocalAddress), PortMath.PortOf(row.LocalPort), (int)row.Pid));
            }
        }
    }

    private static unsafe void ReadUdp6(List<PortRow> rows)
    {
        var size = 0;
        var result = GetExtendedUdpTable(IntPtr.Zero, ref size, false, AfInet6, UdpTableOwnerPid, 0);
        if (result != ErrorInsufficientBuffer || size <= 4)
        {
            return;
        }

        var buffer = new byte[size];
        fixed (byte* pointer = buffer)
        {
            result = GetExtendedUdpTable((IntPtr)pointer, ref size, false, AfInet6, UdpTableOwnerPid, 0);
            if (result != 0)
            {
                return;
            }

            var count = *(uint*)pointer;
            var rowSize = sizeof(Udp6Row);
            var offset = 4;
            for (var index = 0; index < count && offset + rowSize <= size; index++, offset += rowSize)
            {
                var row = *(Udp6Row*)(pointer + offset);
                rows.Add(new PortRow("UDP", FormatV6(row.LocalAddress), PortMath.PortOf(row.LocalPort), (int)row.Pid));
            }
        }
    }

    /// <summary>MIB 里的端口是网络字节序。</summary>
    public static int PortOf(uint port) => (int)(((port & 0xFF) << 8) | ((port >> 8) & 0xFF));

    public static string FormatV4(uint address)
        => $"{address & 0xFF}.{(address >> 8) & 0xFF}.{(address >> 16) & 0xFF}.{(address >> 24) & 0xFF}";

    public static string FormatV6(byte* address)
    {
        var bytes = new byte[16];
        for (var index = 0; index < 16; index++)
        {
            bytes[index] = address[index];
        }

        var ip = new IPAddress(bytes);
        return ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4().ToString() : ip.ToString();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Tcp4Row
    {
        public uint State;
        public uint LocalAddress;
        public uint LocalPort;
        public uint RemoteAddress;
        public uint RemotePort;
        public uint Pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct Tcp6Row
    {
        public fixed byte LocalAddress[16];
        public uint LocalScope;
        public uint LocalPort;
        public fixed byte RemoteAddress[16];
        public uint RemoteScope;
        public uint RemotePort;
        public uint State;
        public uint Pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Udp4Row
    {
        public uint LocalAddress;
        public uint LocalPort;
        public uint Pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct Udp6Row
    {
        public fixed byte LocalAddress[16];
        public uint LocalScope;
        public uint LocalPort;
        public uint Pid;
    }

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(
        IntPtr table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool order, int family, int tableClass,
        uint reserved);

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedUdpTable(
        IntPtr table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool order, int family, int tableClass,
        uint reserved);
}

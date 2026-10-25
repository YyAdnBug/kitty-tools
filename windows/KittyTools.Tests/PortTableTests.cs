// R18：端口表的字节序 / IPv4 格式（纯函数）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PortTableTests
{
    [TestMethod]
    public void PortsAreNetworkByteOrder()
    {
        Assert.AreEqual(8080, PortMath.PortOf(0x901F));
        Assert.AreEqual(80, PortMath.PortOf(0x5000));
        Assert.AreEqual(443, PortMath.PortOf(0xBB01));
    }

    [TestMethod]
    public void IPv4AddressesFormatLittleEndianBytes()
    {
        Assert.AreEqual("127.0.0.1", PortMath.FormatV4(0x0100007F));
        Assert.AreEqual("0.0.0.0", PortMath.FormatV4(0));
    }
}

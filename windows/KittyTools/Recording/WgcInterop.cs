// WGC（Windows.Graphics.Capture）和 WinRT / D3D11 之间的桥（PLAN-v6 第 1 批）：
// 显示器 / 窗口 → GraphicsCaptureItem；DXGI 设备 → WinRT IDirect3DDevice；帧的 IDirect3DSurface → ID3D11Texture2D。
// 全部走 CsWin32 生成的接口（IGraphicsCaptureItemInterop、IDirect3DDxgiInterfaceAccess），不手写 vtable 下标。
using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.System.Com;
using Windows.Win32.System.WinRT;
using Windows.Win32.System.WinRT.Direct3D11;
using Windows.Win32.System.WinRT.Graphics.Capture;

namespace KittyTools;

internal static unsafe class WgcInterop
{
    private const string CaptureItemClass = "Windows.Graphics.Capture.GraphicsCaptureItem";

    /// <summary>整块显示器。hmonitor 是 HMONITOR 的 IntPtr。</summary>
    public static GraphicsCaptureItem? ForMonitor(IntPtr hmonitor)
        => Create(false, hmonitor);

    /// <summary>单个顶层窗口（窗口挪动、被挡住都照录）。</summary>
    public static GraphicsCaptureItem? ForWindow(IntPtr hwnd)
        => Create(true, hwnd);

    private static GraphicsCaptureItem? Create(bool window, IntPtr handle)
    {
        PInvoke.WindowsCreateString(CaptureItemClass, (uint)CaptureItemClass.Length, out var name).ThrowOnFailure();
        try
        {
            PInvoke.RoGetActivationFactory(name, out IGraphicsCaptureItemInterop* factory).ThrowOnFailure();
            try
            {
                void* result = null;
                var iid = typeof(IInspectable).GUID;
                if (window)
                {
                    factory->CreateForWindow(new HWND(handle), &iid, &result);
                }
                else
                {
                    factory->CreateForMonitor(new HMONITOR(handle), &iid, &result);
                }

                try
                {
                    return WinRT.MarshalInspectable<GraphicsCaptureItem>.FromAbi((IntPtr)result);
                }
                finally
                {
                    Marshal.Release((IntPtr)result);
                }
            }
            finally
            {
                ((IUnknown*)factory)->Release();
            }
        }
        finally
        {
            name.Dispose();
        }
    }

    /// <summary>DXGI 设备 → WinRT 的 IDirect3DDevice，给帧池用。</summary>
    public static IDirect3DDevice CreateWinRtDevice(ID3D11Device* device)
    {
        var iid = typeof(IDXGIDevice).GUID;
        IDXGIDevice* dxgi = null;
        device->QueryInterface(&iid, (void**)&dxgi).ThrowOnFailure();
        try
        {
            IInspectable* inspectable = null;
            PInvoke.CreateDirect3D11DeviceFromDXGIDevice(dxgi, &inspectable).ThrowOnFailure();
            try
            {
                return WinRT.MarshalInterface<IDirect3DDevice>.FromAbi((IntPtr)inspectable);
            }
            finally
            {
                Marshal.Release((IntPtr)inspectable);
            }
        }
        finally
        {
            dxgi->Release();
        }
    }

    /// <summary>帧的 surface → 真正的 ID3D11Texture2D（AddRef 过的，调用方 Release）。</summary>
    public static ID3D11Texture2D* TextureOf(IDirect3DSurface surface)
    {
        var abi = WinRT.MarshalInspectable<object>.FromManaged(surface);
        try
        {
            var iid = typeof(IDirect3DDxgiInterfaceAccess).GUID;
            var hr = Marshal.QueryInterface(abi, in iid, out var access);
            if (hr < 0)
            {
                Marshal.ThrowExceptionForHR(hr);
            }

            try
            {
                ((IDirect3DDxgiInterfaceAccess*)access)->GetInterface<ID3D11Texture2D>(out var texture);
                return texture;
            }
            finally
            {
                Marshal.Release(access);
            }
        }
        finally
        {
            Marshal.Release(abi);
        }
    }

    /// <summary>ID3D11Texture2D → Win2D / WinRT 的 IDirect3DSurface。</summary>
    public static IDirect3DSurface SurfaceOf(ID3D11Texture2D* texture)
    {
        var iid = typeof(IDXGISurface).GUID;
        IDXGISurface* dxgi = null;
        texture->QueryInterface(&iid, (void**)&dxgi).ThrowOnFailure();
        try
        {
            IInspectable* inspectable = null;
            PInvoke.CreateDirect3D11SurfaceFromDXGISurface(dxgi, &inspectable).ThrowOnFailure();
            try
            {
                return WinRT.MarshalInterface<IDirect3DSurface>.FromAbi((IntPtr)inspectable);
            }
            finally
            {
                Marshal.Release((IntPtr)inspectable);
            }
        }
        finally
        {
            dxgi->Release();
        }
    }
}

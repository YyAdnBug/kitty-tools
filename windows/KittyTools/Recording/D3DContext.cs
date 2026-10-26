// 录屏用的 D3D11 设备（PLAN-v6 第 1 批）：先试硬件，再退 WARP；开多线程保护（WGC 回调线程和编码线程共用）。
// 同时给出 WinRT 的 IDirect3DDevice（帧池要用）。出错返回 null，调用方退 GDI 那条路。
using System.Runtime.InteropServices;
using Windows.Graphics.DirectX.Direct3D11;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Direct3D;
using Windows.Win32.Graphics.Direct3D10;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi;
using Windows.Win32.Graphics.Dxgi.Common;

namespace KittyTools;

internal sealed unsafe class D3DContext : IDisposable
{
    private const uint SdkVersion = 7;

    private D3DContext(ID3D11Device* device, ID3D11DeviceContext* context, IDirect3DDevice winRt)
    {
        Device = device;
        Context = context;
        WinRt = winRt;
    }

    public ID3D11Device* Device { get; }

    public ID3D11DeviceContext* Context { get; }

    public IDirect3DDevice WinRt { get; }

    public static D3DContext? Create(out string? error)
    {
        error = null;
        var flags = D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_BGRA_SUPPORT
                    | D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
        var levels = new[]
        {
            D3D_FEATURE_LEVEL.D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL.D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL.D3D_FEATURE_LEVEL_10_1,
            D3D_FEATURE_LEVEL.D3D_FEATURE_LEVEL_10_0,
        };

        foreach (var driver in new[] { D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_WARP })
        {
            ID3D11Device* device = null;
            ID3D11DeviceContext* context = null;
            D3D_FEATURE_LEVEL level;
            var hr = PInvoke.D3D11CreateDevice(
                null, driver, default, flags, levels, SdkVersion, &device, out level, &context);
            if (hr.Failed || device is null || context is null)
            {
                if (device is not null)
                {
                    device->Release();
                }

                if (context is not null)
                {
                    context->Release();
                }

                error = $"0x{hr.Value:X8}";
                continue;
            }

            try
            {
                ProtectFromMultipleThreads(device);
                var winRt = WgcInterop.CreateWinRtDevice(device);
                Log.Info($"d3d.created driver={driver} level={level}");
                return new D3DContext(device, context, winRt);
            }
            catch (Exception ex)
            {
                error = ex.HResult == 0 ? ex.Message : $"0x{ex.HResult:X8}";
                Log.Warn($"d3d.winrt-device-failed hr=0x{ex.HResult:X8}");
                context->Release();
                device->Release();
            }
        }

        Log.Warn($"d3d.create-failed {error}");
        return null;
    }

    private static void ProtectFromMultipleThreads(ID3D11Device* device)
    {
        var iid = typeof(ID3D10Multithread).GUID;
        ID3D10Multithread* multithread = null;
        var hr = device->QueryInterface(&iid, (void**)&multithread);
        if (hr.Failed || multithread is null)
        {
            Log.Warn($"d3d.multithread-missing 0x{hr.Value:X8}");
            return;
        }

        try
        {
            multithread->SetMultithreadProtected(true);
        }
        finally
        {
            multithread->Release();
        }
    }

    public ID3D11Texture2D* CreateTexture(int width, int height, bool renderTarget)
    {
        var desc = new D3D11_TEXTURE2D_DESC
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = DXGI_FORMAT.DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc = new DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
            Usage = D3D11_USAGE.D3D11_USAGE_DEFAULT,
            BindFlags = renderTarget
                ? D3D11_BIND_FLAG.D3D11_BIND_RENDER_TARGET | D3D11_BIND_FLAG.D3D11_BIND_SHADER_RESOURCE
                : D3D11_BIND_FLAG.D3D11_BIND_SHADER_RESOURCE,
        };
        ID3D11Texture2D* texture = null;
        Device->CreateTexture2D(desc, null, &texture);
        return texture;
    }

    public void Dispose()
    {
        if (Context is not null)
        {
            Context->Release();
        }

        if (Device is not null)
        {
            Device->Release();
        }
    }
}

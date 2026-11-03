// 系统的语言识别（PLAN-v11 C8）：Windows 自带的 Extended Linguistic Services 里的「Microsoft Language Detection」
// （elscore.dll，Windows 7 起都有），只给 Core 的 Langs.Detect 认拉丁字母的原文是哪种语言——以前法 / 德 / 西 / 葡 / 意
// 一律认成英文，第一、第二语言都是拉丁字母的语言时会译错方向，朗读也用错声音。
// 服务第一次用时取一次、一直留着；取不到、认不出时返回 null，Core 照旧按英文。全在本机，不联网。
// ponytail: 取到的服务信息到进程结束都不放（MappingFreeServices 只在退出时有意义）；要省那一点内存再在空闲回收里放。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static unsafe partial class LanguageRecognizer
{
    /// <summary>ELS_GUID_LANGUAGE_DETECTION（elscore.h）。</summary>
    private static readonly Guid LanguageDetection = new("CF7E00B1-909B-4D95-A8F4-611F7C377702");

    private static readonly object Gate = new();
    private static IntPtr _service;
    private static bool _tried;

    /// <summary>文本最可能是哪种语言（「fr」「de」这类标签）；服务用不了、认不出时 null。</summary>
    public static string? Recognize(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        lock (Gate)
        {
            if (!_tried)
            {
                _tried = true;
                _service = OpenService();
            }

            if (_service == IntPtr.Zero)
            {
                return null;
            }

            var bag = new MappingPropertyBag { Size = (nuint)sizeof(MappingPropertyBag) };
            var filled = false;
            try
            {
                int result;
                fixed (char* chars = text)
                {
                    result = MappingRecognizeText(_service, chars, (uint)text.Length, 0, IntPtr.Zero, &bag);
                }

                filled = result >= 0;
                if (!filled || bag.RangesCount == 0 || bag.ResultRanges is null ||
                    bag.ResultRanges[0].Data == IntPtr.Zero || bag.ResultRanges[0].DataSize < 4)
                {
                    return null;
                }

                // pData 是按可能性从高到低排的语言标签，每个以 \0 结尾、最后再多一个 \0；第一个就是最可能的。
                return Marshal.PtrToStringUni(bag.ResultRanges[0].Data);
            }
            catch (Exception ex)
            {
                Log.Warn($"lang.recognize-failed {ex.GetType().Name}");
                return null;
            }
            finally
            {
                if (filled)
                {
                    MappingFreePropertyBag(&bag);
                }
            }
        }
    }

    private static IntPtr OpenService()
    {
        try
        {
            var guid = LanguageDetection;
            var options = new MappingEnumOptions { Size = (nuint)sizeof(MappingEnumOptions), ServiceGuid = &guid };
            IntPtr services;
            uint count;
            var result = MappingGetServices(&options, &services, &count);
            if (result < 0 || count == 0 || services == IntPtr.Zero)
            {
                Log.Warn($"lang.els-unavailable 0x{result:X8}");
                return IntPtr.Zero;
            }

            Log.Info("lang.els-ready");
            return services;
        }
        catch (Exception ex)
        {
            // 精简过的系统上可能连 elscore.dll 都没有：照旧按英文。
            Log.Warn($"lang.els-unavailable {ex.GetType().Name}");
            return IntPtr.Zero;
        }
    }

    /// <summary>MAPPING_ENUM_OPTIONS（elscore.h）；最后两个位域（OnlineService、ServiceType）合在一个 uint 里，都填 0。</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct MappingEnumOptions
    {
        public nuint Size;
        public IntPtr Category;
        public IntPtr InputLanguage;
        public IntPtr OutputLanguage;
        public IntPtr InputScript;
        public IntPtr OutputScript;
        public IntPtr InputContentType;
        public IntPtr OutputContentType;
        public Guid* ServiceGuid;
        public uint Flags;
    }

    /// <summary>MAPPING_DATA_RANGE。</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct MappingDataRange
    {
        public uint StartIndex;
        public uint EndIndex;
        public IntPtr Description;
        public uint DescriptionLength;
        public IntPtr Data;
        public uint DataSize;
        public IntPtr ContentType;
        public IntPtr ActionIds;
        public uint ActionsCount;
        public IntPtr ActionDisplayNames;
    }

    /// <summary>MAPPING_PROPERTY_BAG。</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct MappingPropertyBag
    {
        public nuint Size;
        public MappingDataRange* ResultRanges;
        public uint RangesCount;
        public IntPtr ServiceData;
        public uint ServiceDataSize;
        public IntPtr CallerData;
        public uint CallerDataSize;
        public IntPtr Context;
    }

    [LibraryImport("elscore.dll")]
    private static partial int MappingGetServices(MappingEnumOptions* options, IntPtr* services, uint* count);

    [LibraryImport("elscore.dll")]
    private static partial int MappingRecognizeText(
        IntPtr service, char* text, uint length, uint index, IntPtr options, MappingPropertyBag* bag);

    [LibraryImport("elscore.dll")]
    private static partial int MappingFreePropertyBag(MappingPropertyBag* bag);
}

// 截图遮罩里就地翻译的「原图」（PLAN-v18 S6，照 mac 758c4d44 SelectionView.untranslated）：译文只属于翻的那个选区。
// 翻之前记下选区和那块原图（同一个选区再翻一次留最早那张，再翻也从原图翻）；选区一变（重新框、挪、拉边、D、右键回到待选）
// 就把原图贴回冻结帧；翻到一半选区换了，这份译文不贴。像素都是 BGRA、行紧挨着（宽 × 4）。
namespace KittyTools.Core;

public sealed class InPlaceOriginal
{
    private (RectD Selection, int Left, int Top, int Width, int Height, byte[] Pixels)? _kept;

    /// <summary>冻结帧里现在贴着译文。</summary>
    public bool HasTranslation => _kept is not null;

    /// <summary>这个选区要翻的原图：同一个选区翻过一次，就是记着的那张（冻结帧里那块已经是译文了）；否则 null（照冻结帧裁）。</summary>
    public byte[]? OriginalFor(RectD selection)
        => _kept is { } kept && kept.Selection == selection ? kept.Pixels : null;

    /// <summary>翻完、要贴之前：记下原图（同一个选区再翻留最早那张）。</summary>
    public void Remember(RectD selection, int left, int top, int width, int height, byte[] original)
    {
        if (_kept is { } kept && kept.Selection == selection)
        {
            return;
        }

        _kept = (selection, left, top, width, height, original);
    }

    /// <summary>
    /// 选区变了（current = null：没有选区，或选区不在这块屏上）：贴着译文的话把原图贴回 frame，返回 true（调用方重建位图、提示一句）。
    /// </summary>
    public bool RestoreIfChanged(RectD? current, byte[] frame, int frameWidth)
    {
        if (_kept is not { } kept || current == kept.Selection)
        {
            return false;
        }

        _kept = null;
        Paste(frame, frameWidth, kept.Pixels, kept.Left, kept.Top, kept.Width, kept.Height);
        return true;
    }

    /// <summary>忘掉（冻结帧整个换了：截图会话结束）。</summary>
    public void Clear() => _kept = null;

    /// <summary>把 width × height 的一块贴到 frame 的 (left, top)。</summary>
    public static void Paste(byte[] frame, int frameWidth, byte[] patch, int left, int top, int width, int height)
    {
        for (var row = 0; row < height; row++)
        {
            Buffer.BlockCopy(patch, row * width * 4, frame, ((top + row) * frameWidth + left) * 4, width * 4);
        }
    }
}

// 识字认码（REVIEW R105）用的里德-所罗门纠错：GF(2^m) 的乘除表，Berlekamp-Massey 求错误位置多项式、Chien 搜索找位置、
// Forney 算错误值，纠完再验一遍伴随式。二维码用 GF(256)：本原多项式 0x11D，生成多项式的根从 α^0 起（ISO/IEC 18004）。
// 照教科书的写法自己写的，不依赖别的库；FirstRoot 留着是给根从 α^1 起的码制（DataMatrix、Aztec）用的。
namespace KittyTools.Core.Barcodes;

public sealed class GaloisField
{
    public static readonly GaloisField QrCode = new(0x11D, 256, 0);

    private readonly int[] _exp;
    private readonly int[] _log;

    public GaloisField(int primitive, int size, int firstRoot)
    {
        Size = size;
        FirstRoot = firstRoot;
        _exp = new int[size * 2];
        _log = new int[size];
        var x = 1;
        for (var i = 0; i < size - 1; i++)
        {
            _exp[i] = x;
            _log[x] = i;
            x <<= 1;
            if (x >= size)
            {
                x ^= primitive;
            }
        }

        for (var i = size - 1; i < size * 2; i++)
        {
            _exp[i] = _exp[i - (size - 1)];
        }
    }

    /// <summary>域里有几个元素（GF(256) 是 256）。</summary>
    public int Size { get; }

    /// <summary>生成多项式的第一个根是 α 的几次方。</summary>
    public int FirstRoot { get; }

    public int Multiply(int a, int b) => a == 0 || b == 0 ? 0 : _exp[_log[a] + _log[b]];

    /// <summary>a / b，b 不能是 0。</summary>
    public int Divide(int a, int b) => a == 0 ? 0 : _exp[_log[a] + (Size - 1) - _log[b]];

    /// <summary>α 的 power 次方（power 可以是负数）。</summary>
    public int Alpha(int power)
    {
        var order = Size - 1;
        return _exp[((power % order) + order) % order];
    }
}

public static class ReedSolomon
{
    /// <summary>
    /// 就地纠正一个码字块：codewords 照传输顺序（高次项在前），最后 eccCount 个是纠错码。
    /// 能纠正（或本来就没错）返回 true；错得比纠错能力多返回 false，codewords 里的值这时不可信。
    /// </summary>
    public static bool Correct(GaloisField field, int[] codewords, int eccCount)
    {
        if (eccCount <= 0)
        {
            return true;
        }

        var n = codewords.Length;
        if (n > field.Size - 1)
        {
            return false;
        }

        var syndromes = new int[eccCount];
        if (ComputeSyndromes(field, codewords, syndromes))
        {
            return true;
        }

        // Berlekamp-Massey：错误位置多项式 C(x) = 1 + C1·x + …
        var c = new int[eccCount + 1];
        var b = new int[eccCount + 1];
        c[0] = 1;
        b[0] = 1;
        var length = 0;
        var shift = 1;
        var lastDiscrepancy = 1;
        for (var k = 0; k < eccCount; k++)
        {
            var d = syndromes[k];
            for (var i = 1; i <= length; i++)
            {
                d ^= field.Multiply(c[i], syndromes[k - i]);
            }

            if (d == 0)
            {
                shift++;
                continue;
            }

            var coefficient = field.Divide(d, lastDiscrepancy);
            if (2 * length <= k)
            {
                var previous = (int[])c.Clone();
                for (var i = 0; i + shift <= eccCount; i++)
                {
                    c[i + shift] ^= field.Multiply(coefficient, b[i]);
                }

                length = k + 1 - length;
                b = previous;
                lastDiscrepancy = d;
                shift = 1;
            }
            else
            {
                for (var i = 0; i + shift <= eccCount; i++)
                {
                    c[i + shift] ^= field.Multiply(coefficient, b[i]);
                }

                shift++;
            }
        }

        if (length == 0 || 2 * length > eccCount)
        {
            return false;
        }

        // Chien 搜索：C(α^-p) = 0 说明 p 次项（下标 n-1-p）错了
        var positions = new List<int>(length);
        for (var p = 0; p < n; p++)
        {
            var x = field.Alpha(-p);
            var value = 0;
            for (var i = length; i >= 0; i--)
            {
                value = field.Multiply(value, x) ^ c[i];
            }

            if (value == 0)
            {
                positions.Add(p);
            }
        }

        if (positions.Count != length)
        {
            return false;
        }

        // Forney：Ω(x) = S(x)·C(x) mod x^eccCount，错误值 = X^(1-b)·Ω(X^-1) / C'(X^-1)
        var omega = new int[eccCount];
        for (var i = 0; i < eccCount; i++)
        {
            var sum = 0;
            for (var j = 0; j <= i && j <= length; j++)
            {
                sum ^= field.Multiply(c[j], syndromes[i - j]);
            }

            omega[i] = sum;
        }

        foreach (var p in positions)
        {
            var inverse = field.Alpha(-p);
            var numerator = 0;
            for (var i = eccCount - 1; i >= 0; i--)
            {
                numerator = field.Multiply(numerator, inverse) ^ omega[i];
            }

            // C'(x) 只剩奇数次项：C1 + C3·x² + C5·x⁴ + …
            var denominator = 0;
            var power = 1;
            var square = field.Multiply(inverse, inverse);
            for (var i = 1; i <= length; i += 2)
            {
                denominator ^= field.Multiply(c[i], power);
                power = field.Multiply(power, square);
            }

            if (denominator == 0)
            {
                return false;
            }

            var magnitude = field.Multiply(field.Alpha(p * (1 - field.FirstRoot)), field.Divide(numerator, denominator));
            codewords[n - 1 - p] ^= magnitude;
        }

        return ComputeSyndromes(field, codewords, syndromes);
    }

    /// <summary>算伴随式填进 syndromes；全是 0（没有错）返回 true。</summary>
    private static bool ComputeSyndromes(GaloisField field, int[] codewords, int[] syndromes)
    {
        var clean = true;
        for (var i = 0; i < syndromes.Length; i++)
        {
            var x = field.Alpha(field.FirstRoot + i);
            var value = 0;
            foreach (var codeword in codewords)
            {
                value = field.Multiply(value, x) ^ codeword;
            }

            syndromes[i] = value;
            if (value != 0)
            {
                clean = false;
            }
        }

        return clean;
    }
}

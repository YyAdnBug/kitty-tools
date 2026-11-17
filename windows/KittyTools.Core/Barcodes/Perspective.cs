// 识字认码（REVIEW R105）：四边形到四边形的透视变换（3×3 单应矩阵）。二维码的模块坐标 → 图上的像素坐标：
// 三个定位图案的中心加右下角的校正图形（没有校正图形时按平行四边形补第四个点），码拍斜了、有透视也能逐个模块取样。
// 正方形到四边形的公式照 Heckbert《Fundamentals of Texture Mapping》，反过来用伴随矩阵（差一个比例，不影响投影）。
namespace KittyTools.Core.Barcodes;

internal readonly struct Perspective
{
    private readonly double _a11, _a12, _a13, _a21, _a22, _a23, _a31, _a32, _a33;

    private Perspective(double a11, double a12, double a13, double a21, double a22, double a23, double a31, double a32, double a33)
    {
        _a11 = a11;
        _a12 = a12;
        _a13 = a13;
        _a21 = a21;
        _a22 = a22;
        _a23 = a23;
        _a31 = a31;
        _a32 = a32;
        _a33 = a33;
    }

    /// <summary>from 的四个点（左上、右上、右下、左下）分别落到 to 的四个点。</summary>
    public static Perspective QuadToQuad(ReadOnlySpan<(double X, double Y)> from, ReadOnlySpan<(double X, double Y)> to)
    {
        var squareToImage = SquareToQuad(to[0], to[1], to[2], to[3]);
        var quadToSquare = SquareToQuad(from[0], from[1], from[2], from[3]).Adjoint();
        return squareToImage.Times(quadToSquare);
    }

    /// <summary>(u, v) → (x, y)。</summary>
    public (double X, double Y) Map(double u, double v)
    {
        var w = _a31 * u + _a32 * v + _a33;
        return ((_a11 * u + _a12 * v + _a13) / w, (_a21 * u + _a22 * v + _a23) / w);
    }

    /// <summary>单位正方形 (0,0) (1,0) (1,1) (0,1) → p0 p1 p2 p3。</summary>
    private static Perspective SquareToQuad((double X, double Y) p0, (double X, double Y) p1, (double X, double Y) p2, (double X, double Y) p3)
    {
        var sx = p0.X - p1.X + p2.X - p3.X;
        var sy = p0.Y - p1.Y + p2.Y - p3.Y;
        if (Math.Abs(sx) < 1e-9 && Math.Abs(sy) < 1e-9)
        {
            return new Perspective(p1.X - p0.X, p2.X - p1.X, p0.X, p1.Y - p0.Y, p2.Y - p1.Y, p0.Y, 0, 0, 1);
        }

        var dx1 = p1.X - p2.X;
        var dx2 = p3.X - p2.X;
        var dy1 = p1.Y - p2.Y;
        var dy2 = p3.Y - p2.Y;
        var den = dx1 * dy2 - dx2 * dy1;
        var g = (sx * dy2 - dx2 * sy) / den;
        var h = (dx1 * sy - sx * dy1) / den;
        return new Perspective(
            p1.X - p0.X + g * p1.X, p3.X - p0.X + h * p3.X, p0.X,
            p1.Y - p0.Y + g * p1.Y, p3.Y - p0.Y + h * p3.Y, p0.Y,
            g, h, 1);
    }

    private Perspective Adjoint() => new(
        _a22 * _a33 - _a23 * _a32, _a13 * _a32 - _a12 * _a33, _a12 * _a23 - _a13 * _a22,
        _a23 * _a31 - _a21 * _a33, _a11 * _a33 - _a13 * _a31, _a13 * _a21 - _a11 * _a23,
        _a21 * _a32 - _a22 * _a31, _a12 * _a31 - _a11 * _a32, _a11 * _a22 - _a12 * _a21);

    /// <summary>先做 o 再做自己。</summary>
    private Perspective Times(Perspective o) => new(
        _a11 * o._a11 + _a12 * o._a21 + _a13 * o._a31, _a11 * o._a12 + _a12 * o._a22 + _a13 * o._a32, _a11 * o._a13 + _a12 * o._a23 + _a13 * o._a33,
        _a21 * o._a11 + _a22 * o._a21 + _a23 * o._a31, _a21 * o._a12 + _a22 * o._a22 + _a23 * o._a32, _a21 * o._a13 + _a22 * o._a23 + _a23 * o._a33,
        _a31 * o._a11 + _a32 * o._a21 + _a33 * o._a31, _a31 * o._a12 + _a32 * o._a22 + _a33 * o._a32, _a31 * o._a13 + _a32 * o._a23 + _a33 * o._a33);
}

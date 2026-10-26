// 每帧八叉树调色板量化（PLAN-v6 第 3 批）：把一帧 BGRA 降到最多 256 色，给 GIF 的局部调色板用。
// 纯函数，配单测；不依赖 WIC / Win2D。做法是标准的八叉树：按颜色位逐层建树，叶子累加颜色和像素数，
// 超过 256 个叶子就把最深一层的父节点合成一个叶子，直到 ≤ 256。
namespace KittyTools.Core;

public static class OctreeQuantizer
{
    private sealed class Node
    {
        public Node?[] Children = new Node?[8];
        public bool Leaf;
        public long Count;
        public long SumR;
        public long SumG;
        public long SumB;
        public int Index;
    }

    /// <summary>返回（每个像素的调色板下标，256 × RGB 调色板）。</summary>
    public static (byte[] Indices, byte[] Palette) Quantize(byte[] bgra, int width, int height, int maxColors = 256)
    {
        var pixels = Math.Max(0, width * height);
        if (pixels == 0 || bgra.Length < pixels * 4)
        {
            return (Array.Empty<byte>(), new byte[256 * 3]);
        }

        var root = new Node();
        var levels = new List<Node>[9];
        for (var level = 0; level <= 8; level++)
        {
            levels[level] = new List<Node>();
        }

        for (var index = 0; index < pixels; index++)
        {
            var offset = index * 4;
            Insert(root, bgra[offset + 2], bgra[offset + 1], bgra[offset], 0, levels);
        }

        var leaves = CountLeaves(root);
        for (var level = 8; level >= 1 && leaves > maxColors; level--)
        {
            foreach (var node in levels[level])
            {
                if (node.Leaf)
                {
                    continue;
                }

                var before = CollapseCount(node);
                Merge(node);
                leaves -= before - 1;
            }
        }

        var palette = new byte[256 * 3];
        var next = 0;
        Assign(root, palette, ref next);
        var indices = new byte[pixels];
        for (var index = 0; index < pixels; index++)
        {
            var offset = index * 4;
            indices[index] = (byte)Lookup(root, bgra[offset + 2], bgra[offset + 1], bgra[offset], 0);
        }

        return (indices, palette);
    }

    private static void Insert(
        Node node, byte red, byte green, byte blue, int level, List<Node>[] levels)
    {
        if (node.Leaf)
        {
            node.Count++;
            node.SumR += red;
            node.SumG += green;
            node.SumB += blue;
            return;
        }

        if (level >= 8)
        {
            node.Leaf = true;
            node.Count = 1;
            node.SumR = red;
            node.SumG = green;
            node.SumB = blue;
            return;
        }

        var shift = 7 - level;
        var index = ((red >> shift) & 1) << 2 | ((green >> shift) & 1) << 1 | ((blue >> shift) & 1);
        var child = node.Children[index];
        if (child is null)
        {
            child = new Node();
            node.Children[index] = child;
            levels[level + 1].Add(child);
        }

        Insert(child, red, green, blue, level + 1, levels);
    }

    private static long CountLeaves(Node node)
    {
        if (node.Leaf)
        {
            return 1;
        }

        long count = 0;
        foreach (var child in node.Children)
        {
            if (child is not null)
            {
                count += CountLeaves(child);
            }
        }

        return count;
    }

    private static long CollapseCount(Node node)
    {
        if (node.Leaf)
        {
            return 1;
        }

        long count = 0;
        foreach (var child in node.Children)
        {
            if (child is not null)
            {
                count += CollapseCount(child);
            }
        }

        return count;
    }

    private static void Merge(Node node)
    {
        long count = 0;
        long red = 0;
        long green = 0;
        long blue = 0;
        foreach (var child in node.Children)
        {
            if (child is null)
            {
                continue;
            }

            Accumulate(child, ref count, ref red, ref green, ref blue);
        }

        Array.Clear(node.Children);
        node.Leaf = true;
        node.Count = count;
        node.SumR = red;
        node.SumG = green;
        node.SumB = blue;
    }

    private static void Accumulate(Node node, ref long count, ref long red, ref long green, ref long blue)
    {
        if (node.Leaf)
        {
            count += node.Count;
            red += node.SumR;
            green += node.SumG;
            blue += node.SumB;
            return;
        }

        foreach (var child in node.Children)
        {
            if (child is not null)
            {
                Accumulate(child, ref count, ref red, ref green, ref blue);
            }
        }
    }

    private static void Assign(Node node, byte[] palette, ref int next)
    {
        if (node.Leaf)
        {
            var index = Math.Min(255, next);
            var count = Math.Max(1, node.Count);
            palette[index * 3] = (byte)(node.SumR / count);
            palette[index * 3 + 1] = (byte)(node.SumG / count);
            palette[index * 3 + 2] = (byte)(node.SumB / count);
            node.Index = index;
            next++;
            return;
        }

        foreach (var child in node.Children)
        {
            if (child is not null)
            {
                Assign(child, palette, ref next);
            }
        }
    }

    private static int Lookup(Node node, byte red, byte green, byte blue, int level)
    {
        if (node.Leaf)
        {
            return node.Index;
        }

        var shift = 7 - level;
        var index = ((red >> shift) & 1) << 2 | ((green >> shift) & 1) << 1 | ((blue >> shift) & 1);
        var child = node.Children[index];
        return child is null ? node.Index : Lookup(child, red, green, blue, level + 1);
    }
}

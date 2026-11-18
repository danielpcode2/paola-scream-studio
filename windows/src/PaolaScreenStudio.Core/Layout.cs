namespace PaolaScreenStudio.Core;

public readonly record struct Box(double X, double Y, double W, double H)
{
    public double Right => X + W;
    public double Bottom => Y + H;
    public double CenterX => X + W / 2;
    public double CenterY => Y + H / 2;
}

/// <summary>Geometry shared by the editor preview and the exporter, so both look the same.</summary>
public static class Layout
{
    /// <summary>Output size for a target height, never upscaling the recording; even numbers for H.264.</summary>
    public static (int W, int H) OutputSize(int sourceW, int sourceH, int targetH)
    {
        if (sourceW <= 0 || sourceH <= 0)
        {
            return (Even(targetH * 16 / 9.0), Even(targetH));
        }
        var h = Math.Min(targetH, sourceH);
        return (Even(h * (double)sourceW / sourceH), Even(h));
    }

    public static Box Content(double outW, double outH, double sourceW, double sourceH, EditSettings s)
    {
        var shortSide = Math.Min(outW, outH);
        var pad = s.Background == BackgroundKind.None ? 0 : s.Padding * shortSide;
        var availableW = Math.Max(1, outW - 2 * pad);
        var availableH = Math.Max(1, outH - 2 * pad);
        var scale = Math.Min(availableW / Math.Max(1, sourceW), availableH / Math.Max(1, sourceH));
        var w = sourceW * scale;
        var h = sourceH * scale;
        return new Box((outW - w) / 2, (outH - h) / 2, w, h);
    }

    public static double CornerRadius(double outW, double outH, EditSettings s) =>
        s.Background == BackgroundKind.None ? 0 : s.CornerRadius * Math.Min(outW, outH);

    public static Box Camera(double outW, double outH, EditSettings s)
    {
        var shortSide = Math.Min(outW, outH);
        var d = s.CameraSize * shortSide;
        var margin = 0.03 * shortSide;
        var left = margin;
        var right = outW - margin - d;
        var top = margin;
        var bottom = outH - margin - d;
        return s.CameraCorner switch
        {
            CameraCorner.BottomLeft => new Box(left, bottom, d, d),
            CameraCorner.TopRight => new Box(right, top, d, d),
            CameraCorner.TopLeft => new Box(left, top, d, d),
            _ => new Box(right, bottom, d, d),
        };
    }

    /// <summary>Corner radius of the camera bubble for its shape (half = half the side).</summary>
    public static double ShapeRadius(CameraShape shape, double half) => shape switch
    {
        CameraShape.Circle => half,
        CameraShape.Rounded => half * 0.32,
        _ => half * 0.06,
    };

    public static double BorderWidth(double half) => Math.Max(1.5, half * 0.024);

    public static int Even(double value) => Math.Max(2, (int)Math.Round(value / 2) * 2);
}

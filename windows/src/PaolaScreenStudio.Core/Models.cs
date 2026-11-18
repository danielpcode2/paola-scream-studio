using System.Text.Json.Serialization;

namespace PaolaScreenStudio.Core;

public sealed class CursorSample
{
    /// <summary>Seconds from the start of the recording.</summary>
    public double T { get; set; }
    /// <summary>Pixels relative to the captured area.</summary>
    public double X { get; set; }
    public double Y { get; set; }
}

public sealed class ClickEvent
{
    public double T { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
}

public sealed class RecordingInfo
{
    public string ScreenFile { get; set; } = "recording.mp4";
    public string? CameraFile { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public double Duration { get; set; }
    /// <summary>Camera time = screen time - CameraOffset.</summary>
    public double CameraOffset { get; set; }
    public List<CursorSample> Cursor { get; set; } = new();
    public List<ClickEvent> Clicks { get; set; } = new();
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum BackgroundKind { Gradient, Color, None }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum CameraShape { Circle, Rounded, Square }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum CameraCorner { BottomRight, BottomLeft, TopRight, TopLeft }

public sealed record Rgba(byte R, byte G, byte B, byte A = 255)
{
    public static readonly Rgba White = new(255, 255, 255, 242);
    public static readonly Rgba Transparent = new(255, 255, 255, 0);

    public string Hex => $"#{R:X2}{G:X2}{B:X2}";

    public static Rgba? FromHex(string text)
    {
        var hex = text.Trim().TrimStart('#');
        if (hex.Length != 6 || !int.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var value))
        {
            return null;
        }
        return new Rgba((byte)(value >> 16), (byte)(value >> 8 & 0xFF), (byte)(value & 0xFF));
    }
}

public sealed record GradientPreset(string Name, Rgba Start, Rgba End)
{
    public static readonly IReadOnlyList<GradientPreset> All = new GradientPreset[]
    {
        new("Océano", new(38, 115, 242), new(115, 51, 217)),
        new("Atardecer", new(250, 140, 77), new(230, 64, 128)),
        new("Bosque", new(26, 140, 115), new(140, 204, 89)),
        new("Medianoche", new(18, 20, 46), new(56, 46, 102)),
        new("Lavanda", new(204, 179, 250), new(250, 199, 219)),
        new("Grafito", new(46, 46, 51), new(97, 97, 107)),
        new("Menta", new(158, 242, 217), new(102, 179, 242)),
        new("Paola", new(255, 92, 158), new(124, 58, 237)),
    };
}

/// <summary>A span on the timeline (zoom or cut).</summary>
public interface ISpan
{
    Guid Id { get; }
    double Start { get; set; }
    double End { get; set; }
}

public sealed class ZoomSegment : ISpan
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double Start { get; set; }
    public double End { get; set; }
    public double Scale { get; set; } = 1.8;
    /// <summary>Fixed focus (0..1). Null = follow the cursor.</summary>
    public double? FocusX { get; set; }
    public double? FocusY { get; set; }
}

public sealed class CutSegment : ISpan
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double Start { get; set; }
    public double End { get; set; }
}

public sealed class EditSettings
{
    public BackgroundKind Background { get; set; } = BackgroundKind.Gradient;
    public int GradientIndex { get; set; } = 7;
    public Rgba BackgroundColor { get; set; } = new(31, 31, 36);
    /// <summary>Fraction of the shorter output side.</summary>
    public double Padding { get; set; } = 0.07;
    public double CornerRadius { get; set; } = 0.015;
    public double Shadow { get; set; } = 0.5;

    public bool ShowCamera { get; set; } = true;
    /// <summary>Bubble diameter as a fraction of the shorter output side.</summary>
    public double CameraSize { get; set; } = 0.24;
    public CameraCorner CameraCorner { get; set; } = CameraCorner.BottomRight;
    public CameraShape CameraShape { get; set; } = CameraShape.Circle;
    public Rgba CameraBorderColor { get; set; } = Rgba.White;
    public bool MirrorCamera { get; set; } = true;

    public bool ShowClicks { get; set; } = true;
    public double AutoZoomScale { get; set; } = 1.8;
    public List<ZoomSegment> Zooms { get; set; } = new();
    public List<CutSegment> Cuts { get; set; } = new();
    public double TrimStart { get; set; }
    public double? TrimEnd { get; set; }

    public GradientPreset Gradient => GradientPreset.All[Math.Clamp(GradientIndex, 0, GradientPreset.All.Count - 1)];
}

public sealed class Project
{
    public int Version { get; set; } = 1;
    public string Name { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public RecordingInfo Recording { get; set; } = new();
    public EditSettings Settings { get; set; } = new();
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ExportFormat { Mp4, Gif }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ExportQuality { High, Medium, Low }

public sealed class ExportOptions
{
    public int Height { get; set; } = 1080;
    public int Fps { get; set; } = 60;
    public ExportFormat Format { get; set; } = ExportFormat.Mp4;
    public ExportQuality Quality { get; set; } = ExportQuality.High;
}

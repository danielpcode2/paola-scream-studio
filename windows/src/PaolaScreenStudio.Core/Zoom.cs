namespace PaolaScreenStudio.Core;

/// <summary>Visible part of the recording: scale and center, both normalized (0..1).</summary>
public readonly record struct ZoomState(double Scale, double CenterX, double CenterY)
{
    public static readonly ZoomState None = new(1, 0.5, 0.5);

    /// <summary>Visible source rect, normalized.</summary>
    public (double X, double Y, double W, double H) SourceRect
    {
        get
        {
            var size = 1 / Scale;
            return (CenterX - size / 2, CenterY - size / 2, size, size);
        }
    }
}

/// <summary>Cursor positions over time with smoothing for a calm camera.</summary>
public sealed class CursorPath
{
    private readonly CursorSample[] samples;
    private readonly double[] times;
    private readonly double width;
    private readonly double height;

    public CursorPath(IEnumerable<CursorSample> samples, int width, int height)
    {
        this.samples = samples.OrderBy(s => s.T).ToArray();
        times = this.samples.Select(s => s.T).ToArray();
        this.width = Math.Max(1, width);
        this.height = Math.Max(1, height);
    }

    /// <summary>Normalized position at time t (linear interpolation).</summary>
    public (double X, double Y) At(double t)
    {
        if (samples.Length == 0)
        {
            return (0.5, 0.5);
        }
        var index = Array.BinarySearch(times, t);
        if (index < 0)
        {
            index = ~index;
        }
        if (index <= 0)
        {
            return Normalize(samples[0].X, samples[0].Y);
        }
        if (index >= samples.Length)
        {
            return Normalize(samples[^1].X, samples[^1].Y);
        }
        var a = samples[index - 1];
        var b = samples[index];
        var f = b.T - a.T < 1e-6 ? 0 : (t - a.T) / (b.T - a.T);
        return Normalize(a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f);
    }

    /// <summary>Average position over ±0.35 s so the zoom glides instead of jittering.</summary>
    public (double X, double Y) Smoothed(double t)
    {
        const int steps = 8;
        double x = 0, y = 0;
        for (var i = 0; i <= steps; i++)
        {
            var p = At(t - 0.35 + 0.7 * i / steps);
            x += p.X;
            y += p.Y;
        }
        return (x / (steps + 1), y / (steps + 1));
    }

    private (double, double) Normalize(double x, double y) => (Math.Clamp(x / width, 0, 1), Math.Clamp(y / height, 0, 1));
}

public static class ZoomPlanner
{
    public const double Ramp = 0.45;

    /// <summary>One zoom per burst of clicks: from 0.5 s before the first click to 2 s after the last.</summary>
    public static List<ZoomSegment> Auto(IEnumerable<ClickEvent> clicks, double duration, double scale)
    {
        var result = new List<ZoomSegment>();
        foreach (var click in clicks.OrderBy(c => c.T))
        {
            var start = Math.Max(0, click.T - 0.5);
            var end = Math.Min(duration, click.T + 2.0);
            if (result.Count > 0 && start - result[^1].End < 0.8)
            {
                result[^1].End = Math.Max(result[^1].End, end);
                continue;
            }
            if (end - start >= 0.5)
            {
                result.Add(new ZoomSegment { Start = start, End = end, Scale = scale });
            }
        }
        return result;
    }

    public static ZoomState At(double t, IReadOnlyList<ZoomSegment> segments, CursorPath cursor)
    {
        foreach (var segment in segments)
        {
            if (t < segment.Start || t > segment.End)
            {
                continue;
            }
            var ramp = Math.Min(Ramp, (segment.End - segment.Start) / 2);
            var edge = Math.Min(t - segment.Start, segment.End - t);
            var progress = ramp <= 0 ? 1 : Ease(Math.Clamp(edge / ramp, 0, 1));
            var scale = 1 + (Math.Max(1, segment.Scale) - 1) * progress;
            var focus = segment.FocusX is double fx && segment.FocusY is double fy ? (fx, fy) : cursor.Smoothed(t);
            var cx = 0.5 + (focus.Item1 - 0.5) * progress;
            var cy = 0.5 + (focus.Item2 - 0.5) * progress;
            return Clamp(new ZoomState(scale, cx, cy));
        }
        return ZoomState.None;
    }

    /// <summary>Keeps the visible rect inside the recording.</summary>
    public static ZoomState Clamp(ZoomState state)
    {
        var half = 0.5 / state.Scale;
        return state with
        {
            CenterX = Math.Clamp(state.CenterX, half, 1 - half),
            CenterY = Math.Clamp(state.CenterY, half, 1 - half),
        };
    }

    private static double Ease(double x) => x * x * (3 - 2 * x);
}

/// <summary>Move, resize and insert spans without overlaps.</summary>
public static class SpanEditing
{
    public const double MinLength = 0.3;

    public static void Move<T>(List<T> spans, T span, double newStart, double duration) where T : ISpan
    {
        var length = span.End - span.Start;
        var (low, high) = Bounds(spans, span, duration);
        var start = Math.Clamp(newStart, low, Math.Max(low, high - length));
        span.Start = start;
        span.End = Math.Min(high, start + length);
    }

    public static void ResizeStart<T>(List<T> spans, T span, double newStart, double duration) where T : ISpan
    {
        var (low, _) = Bounds(spans, span, duration);
        span.Start = Math.Clamp(newStart, low, span.End - MinLength);
    }

    public static void ResizeEnd<T>(List<T> spans, T span, double newEnd, double duration) where T : ISpan
    {
        var (_, high) = Bounds(spans, span, duration);
        span.End = Math.Clamp(newEnd, span.Start + MinLength, high);
    }

    /// <summary>Largest free gap around <paramref name="time"/>, at most <paramref name="length"/> long; null if there is no room.</summary>
    public static (double Start, double End)? FreeSlot<T>(IEnumerable<T> spans, double time, double length, double duration) where T : ISpan
    {
        if (time < 0 || time > duration)
        {
            return null;
        }
        double low = 0, high = duration;
        foreach (var span in spans)
        {
            if (time >= span.Start && time <= span.End)
            {
                return null;
            }
            if (span.End <= time)
            {
                low = Math.Max(low, span.End);
            }
            if (span.Start >= time)
            {
                high = Math.Min(high, span.Start);
            }
        }
        if (high - low < MinLength)
        {
            return null;
        }
        var start = Math.Clamp(time, low, Math.Max(low, high - length));
        return (start, Math.Min(high, start + length));
    }

    private static (double Low, double High) Bounds<T>(IEnumerable<T> spans, T span, double duration) where T : ISpan
    {
        double low = 0, high = duration;
        foreach (var other in spans)
        {
            if (other.Id == span.Id)
            {
                continue;
            }
            if (other.End <= span.Start + 1e-6)
            {
                low = Math.Max(low, other.End);
            }
            else if (other.Start >= span.End - 1e-6)
            {
                high = Math.Min(high, other.Start);
            }
        }
        return (low, high);
    }
}

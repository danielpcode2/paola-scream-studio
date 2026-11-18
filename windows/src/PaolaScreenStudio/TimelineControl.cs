using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

/// <summary>
/// Ruler, video lane (trim handles and cuts) and zoom lane. Drag spans to move them, drag their edges to
/// resize, double-click an empty spot to add one, right-click a span for its options.
/// </summary>
internal sealed class TimelineControl : FrameworkElement
{
    private const double Side = 14;
    private const double RulerBottom = 22;
    private const double VideoTop = 30;
    private const double VideoBottom = 74;
    private const double ZoomTop = 84;
    private const double ZoomBottom = 124;
    private const double Edge = 7;

    private static readonly Brush LaneBrush = new SolidColorBrush(Color.FromRgb(38, 38, 48));
    private static readonly Brush VideoBrush = new SolidColorBrush(Color.FromRgb(58, 58, 74));
    private static readonly Brush TrimmedBrush = new SolidColorBrush(Color.FromArgb(200, 10, 10, 14));
    private static readonly Brush CutBrush = new SolidColorBrush(Color.FromArgb(200, 255, 77, 109));
    private static readonly Brush ZoomBrush = new SolidColorBrush(Color.FromRgb(124, 58, 237));
    private static readonly Brush ZoomFixedBrush = new SolidColorBrush(Color.FromRgb(236, 72, 153));
    private static readonly Brush GhostBrush = new SolidColorBrush(Color.FromArgb(70, 139, 92, 246));
    private static readonly Brush PlayheadBrush = new SolidColorBrush(Color.FromRgb(255, 92, 158));
    private static readonly Brush MutedBrush = new SolidColorBrush(Color.FromRgb(154, 154, 168));
    private static readonly Pen SelectedPen = new(Brushes.White, 2);
    private static readonly Pen TickPen = new(new SolidColorBrush(Color.FromRgb(70, 70, 84)), 1);
    private static readonly Typeface Face = new("Segoe UI");

    private enum DragMode { None, Seek, Move, ResizeStart, ResizeEnd, TrimStart, TrimEnd }

    private DragMode mode;
    private ISpan? dragSpan;
    private double dragOffset;
    private Point? hover;

    public EditSettings Settings { get; set; } = new();
    public double Duration { get; set; } = 1;
    public double Playhead { get; set; }
    public ISpan? Selected { get; set; }

    /// <summary>Called before a change so it can be undone.</summary>
    public event Action? WillChange;
    public event Action? Changed;
    public event Action<double>? SeekRequested;
    public event Action<ISpan?>? SelectionChanged;

    public TimelineControl()
    {
        Height = 140;
        Focusable = true;
        ClipToBounds = true;
    }

    private double X(double t) => Side + t / Math.Max(0.001, Duration) * Math.Max(1, ActualWidth - 2 * Side);

    private double T(double x) => Math.Clamp((x - Side) / Math.Max(1, ActualWidth - 2 * Side) * Duration, 0, Duration);

    protected override void OnRender(DrawingContext dc)
    {
        var width = ActualWidth;
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, width, ActualHeight));

        // Ruler.
        var step = TickStep();
        for (var t = 0.0; t <= Duration + 1e-6; t += step)
        {
            var x = X(t);
            dc.DrawLine(TickPen, new Point(x, RulerBottom - 6), new Point(x, RulerBottom));
            dc.DrawText(Text(FormatTime(t), 10, MutedBrush), new Point(x + 3, 4));
        }

        // Video lane with trimmed parts and cuts.
        dc.DrawRoundedRectangle(VideoBrush, null, new Rect(X(0), VideoTop, X(Duration) - X(0), VideoBottom - VideoTop), 6, 6);
        dc.DrawText(Text(Strings.T("timeline.video"), 10, MutedBrush), new Point(X(0) + 6, VideoTop + 3));
        var trimEnd = Settings.TrimEnd ?? Duration;
        if (Settings.TrimStart > 0)
        {
            dc.DrawRectangle(TrimmedBrush, null, new Rect(X(0), VideoTop, X(Settings.TrimStart) - X(0), VideoBottom - VideoTop));
        }
        if (trimEnd < Duration)
        {
            dc.DrawRectangle(TrimmedBrush, null, new Rect(X(trimEnd), VideoTop, X(Duration) - X(trimEnd), VideoBottom - VideoTop));
        }
        foreach (var cut in Settings.Cuts)
        {
            var rect = new Rect(X(cut.Start), VideoTop + 4, Math.Max(2, X(cut.End) - X(cut.Start)), VideoBottom - VideoTop - 8);
            dc.DrawRoundedRectangle(CutBrush, ReferenceEquals(cut, Selected) ? SelectedPen : null, rect, 4, 4);
            if (rect.Width > 30)
            {
                dc.DrawText(Text("✂", 12, Brushes.White), new Point(rect.X + 6, rect.Y + 8));
            }
        }
        DrawHandle(dc, X(Settings.TrimStart));
        DrawHandle(dc, X(trimEnd));

        // Zoom lane.
        dc.DrawRoundedRectangle(LaneBrush, null, new Rect(X(0), ZoomTop, X(Duration) - X(0), ZoomBottom - ZoomTop), 6, 6);
        if (Settings.Zooms.Count == 0)
        {
            dc.DrawText(Text(Strings.T("timeline.zoom_hint"), 10, MutedBrush), new Point(X(0) + 8, ZoomTop + 13));
        }
        foreach (var zoom in Settings.Zooms)
        {
            var rect = new Rect(X(zoom.Start), ZoomTop + 3, Math.Max(2, X(zoom.End) - X(zoom.Start)), ZoomBottom - ZoomTop - 6);
            dc.DrawRoundedRectangle(zoom.FocusX == null ? ZoomBrush : ZoomFixedBrush, ReferenceEquals(zoom, Selected) ? SelectedPen : null, rect, 5, 5);
            if (rect.Width > 34)
            {
                dc.DrawText(Text($"🔍 {zoom.Scale.ToString("0.##", CultureInfo.InvariantCulture)}×", 11, Brushes.White), new Point(rect.X + 6, rect.Y + 10));
            }
        }

        // "+" ghost where a click would add a zoom.
        if (hover is Point h && mode == DragMode.None && h.Y >= ZoomTop && h.Y <= ZoomBottom
            && SpanEditing.FreeSlot(Settings.Zooms, T(h.X), 2.5, Duration) is (double gs, double ge))
        {
            var rect = new Rect(X(gs), ZoomTop + 3, X(ge) - X(gs), ZoomBottom - ZoomTop - 6);
            dc.DrawRoundedRectangle(GhostBrush, null, rect, 5, 5);
            dc.DrawText(Text("+", 16, Brushes.White), new Point(rect.X + rect.Width / 2 - 4, rect.Y + 6));
        }

        // Playhead.
        var px = X(Playhead);
        dc.DrawRectangle(PlayheadBrush, null, new Rect(px - 1, 0, 2, ActualHeight));
        dc.DrawEllipse(PlayheadBrush, null, new Point(px, 6), 6, 6);
    }

    private static void DrawHandle(DrawingContext dc, double x)
    {
        dc.DrawRoundedRectangle(Brushes.White, null, new Rect(x - 3, VideoTop - 2, 6, VideoBottom - VideoTop + 4), 3, 3);
    }

    private double TickStep()
    {
        var pixelsPerSecond = Math.Max(1, ActualWidth - 2 * Side) / Math.Max(0.001, Duration);
        foreach (var step in new[] { 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600 })
        {
            if (step * pixelsPerSecond >= 70)
            {
                return step;
            }
        }
        return 1200;
    }

    public static string FormatTime(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    private FormattedText Text(string text, double size, Brush brush) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Face, size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);

    // MARK: Mouse

    private (ISpan Span, DragMode Mode)? HitSpan(Point p)
    {
        IEnumerable<ISpan>? spans = p.Y >= ZoomTop && p.Y <= ZoomBottom ? Settings.Zooms
            : p.Y >= VideoTop && p.Y <= VideoBottom ? Settings.Cuts : null;
        if (spans == null)
        {
            return null;
        }
        foreach (var span in spans)
        {
            double left = X(span.Start), right = X(span.End);
            if (Math.Abs(p.X - left) <= Edge)
            {
                return (span, DragMode.ResizeStart);
            }
            if (Math.Abs(p.X - right) <= Edge)
            {
                return (span, DragMode.ResizeEnd);
            }
            if (p.X > left && p.X < right)
            {
                return (span, DragMode.Move);
            }
        }
        return null;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        Focus();
        var p = e.GetPosition(this);
        if (e.ClickCount == 2)
        {
            AddAt(p);
            return;
        }
        var trimEnd = Settings.TrimEnd ?? Duration;
        if (p.Y >= VideoTop - 2 && p.Y <= VideoBottom + 2 && Math.Abs(p.X - X(Settings.TrimStart)) <= Edge)
        {
            Begin(DragMode.TrimStart, null, 0);
        }
        else if (p.Y >= VideoTop - 2 && p.Y <= VideoBottom + 2 && Math.Abs(p.X - X(trimEnd)) <= Edge)
        {
            Begin(DragMode.TrimEnd, null, 0);
        }
        else if (HitSpan(p) is (ISpan span, DragMode hit))
        {
            Select(span);
            Begin(hit, span, T(p.X) - span.Start);
        }
        else if (p.Y >= ZoomTop && p.Y <= ZoomBottom && SpanEditing.FreeSlot(Settings.Zooms, T(p.X), 2.5, Duration) is not null)
        {
            AddAt(p);
        }
        else
        {
            Select(null);
            Begin(DragMode.Seek, null, 0);
            SeekRequested?.Invoke(T(p.X));
        }
        e.Handled = true;
    }

    private void Begin(DragMode newMode, ISpan? span, double offset)
    {
        if (newMode != DragMode.Seek)
        {
            WillChange?.Invoke();
        }
        mode = newMode;
        dragSpan = span;
        dragOffset = offset;
        CaptureMouse();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        hover = p;
        if (mode == DragMode.None)
        {
            var trimEnd = Settings.TrimEnd ?? Duration;
            var onTrim = p.Y >= VideoTop && p.Y <= VideoBottom && (Math.Abs(p.X - X(Settings.TrimStart)) <= Edge || Math.Abs(p.X - X(trimEnd)) <= Edge);
            var hit = HitSpan(p);
            Cursor = onTrim || hit?.Mode is DragMode.ResizeStart or DragMode.ResizeEnd ? Cursors.SizeWE
                : hit != null ? Cursors.Hand : Cursors.Arrow;
            InvalidateVisual();
            return;
        }
        var t = T(p.X);
        switch (mode)
        {
            case DragMode.Seek:
                SeekRequested?.Invoke(t);
                break;
            case DragMode.TrimStart:
                Settings.TrimStart = Math.Clamp(t, 0, (Settings.TrimEnd ?? Duration) - 0.5);
                SeekRequested?.Invoke(Settings.TrimStart);
                break;
            case DragMode.TrimEnd:
                var end = Math.Clamp(t, Settings.TrimStart + 0.5, Duration);
                Settings.TrimEnd = end >= Duration - 0.01 ? null : end;
                SeekRequested?.Invoke(end);
                break;
            case DragMode.Move when dragSpan is ZoomSegment z:
                SpanEditing.Move(Settings.Zooms, z, t - dragOffset, Duration);
                break;
            case DragMode.Move when dragSpan is CutSegment c:
                SpanEditing.Move(Settings.Cuts, c, t - dragOffset, Duration);
                break;
            case DragMode.ResizeStart when dragSpan is ZoomSegment z:
                SpanEditing.ResizeStart(Settings.Zooms, z, t, Duration);
                break;
            case DragMode.ResizeStart when dragSpan is CutSegment c:
                SpanEditing.ResizeStart(Settings.Cuts, c, t, Duration);
                break;
            case DragMode.ResizeEnd when dragSpan is ZoomSegment z:
                SpanEditing.ResizeEnd(Settings.Zooms, z, t, Duration);
                break;
            case DragMode.ResizeEnd when dragSpan is CutSegment c:
                SpanEditing.ResizeEnd(Settings.Cuts, c, t, Duration);
                break;
        }
        if (mode != DragMode.Seek)
        {
            Changed?.Invoke();
        }
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        mode = DragMode.None;
        dragSpan = null;
        ReleaseMouseCapture();
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        hover = null;
        InvalidateVisual();
    }

    protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
    {
        var p = e.GetPosition(this);
        if (HitSpan(p) is not (ISpan span, _))
        {
            return;
        }
        Select(span);
        var menu = new ContextMenu();
        if (span is ZoomSegment zoom)
        {
            foreach (var level in new[] { 1.25, 1.5, 1.8, 2.0, 2.5, 3.0 })
            {
                var value = level;
                var item = new MenuItem
                {
                    Header = Strings.T("zoom.level", value.ToString("0.##", CultureInfo.CurrentCulture)),
                    IsCheckable = true,
                    IsChecked = Math.Abs(zoom.Scale - value) < 0.01,
                };
                item.Click += (_, _) => Edit(() => zoom.Scale = value);
                menu.Items.Add(item);
            }
            var all = new MenuItem { Header = Strings.T("zoom.apply_all") };
            all.Click += (_, _) => Edit(() => Settings.Zooms.ForEach(z => z.Scale = zoom.Scale));
            menu.Items.Add(all);
            menu.Items.Add(new Separator());
            var follow = new MenuItem { Header = Strings.T("zoom.follow"), IsCheckable = true, IsChecked = zoom.FocusX == null };
            follow.Click += (_, _) => Edit(() => { zoom.FocusX = null; zoom.FocusY = null; });
            menu.Items.Add(follow);
            var fixedFocus = new MenuItem { Header = Strings.T("zoom.fixed"), IsCheckable = true, IsChecked = zoom.FocusX != null };
            fixedFocus.Click += (_, _) => Edit(() => { zoom.FocusX ??= 0.5; zoom.FocusY ??= 0.5; });
            menu.Items.Add(fixedFocus);
            menu.Items.Add(new Separator());
        }
        var duplicate = new MenuItem { Header = Strings.T("item.duplicate"), InputGestureText = "Ctrl+D" };
        duplicate.Click += (_, _) => Duplicate(span);
        menu.Items.Add(duplicate);
        var delete = new MenuItem { Header = Strings.T("item.delete"), InputGestureText = "Supr" };
        delete.Click += (_, _) => DeleteSelected();
        menu.Items.Add(delete);
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void AddAt(Point p)
    {
        var t = T(p.X);
        if (p.Y >= ZoomTop && p.Y <= ZoomBottom)
        {
            AddZoom(t);
        }
        else if (p.Y >= VideoTop && p.Y <= VideoBottom)
        {
            AddCut(t);
        }
    }

    public void AddZoom(double t)
    {
        if (SpanEditing.FreeSlot(Settings.Zooms, t, 2.5, Duration) is not (double start, double end))
        {
            return;
        }
        var zoom = new ZoomSegment { Start = start, End = end, Scale = Settings.AutoZoomScale };
        Edit(() =>
        {
            Settings.Zooms.Add(zoom);
            Settings.Zooms.Sort((a, b) => a.Start.CompareTo(b.Start));
        });
        Select(zoom);
    }

    public void AddCut(double t)
    {
        if (SpanEditing.FreeSlot(Settings.Cuts, t, 1.5, Duration) is not (double start, double end))
        {
            return;
        }
        var cut = new CutSegment { Start = start, End = end };
        Edit(() =>
        {
            Settings.Cuts.Add(cut);
            Settings.Cuts.Sort((a, b) => a.Start.CompareTo(b.Start));
        });
        Select(cut);
    }

    public void Duplicate(ISpan span)
    {
        var length = span.End - span.Start;
        if (span is ZoomSegment z && SpanEditing.FreeSlot(Settings.Zooms, z.End + 0.01, length, Duration) is (double zs, double ze))
        {
            var copy = new ZoomSegment { Start = zs, End = ze, Scale = z.Scale, FocusX = z.FocusX, FocusY = z.FocusY };
            Edit(() => { Settings.Zooms.Add(copy); Settings.Zooms.Sort((a, b) => a.Start.CompareTo(b.Start)); });
            Select(copy);
        }
        else if (span is CutSegment && SpanEditing.FreeSlot(Settings.Cuts, span.End + 0.01, length, Duration) is (double cs, double ce))
        {
            var copy = new CutSegment { Start = cs, End = ce };
            Edit(() => { Settings.Cuts.Add(copy); Settings.Cuts.Sort((a, b) => a.Start.CompareTo(b.Start)); });
            Select(copy);
        }
    }

    public void DeleteSelected()
    {
        switch (Selected)
        {
            case ZoomSegment z:
                Edit(() => Settings.Zooms.Remove(z));
                break;
            case CutSegment c:
                Edit(() => Settings.Cuts.Remove(c));
                break;
            default:
                return;
        }
        Select(null);
    }

    private void Edit(Action change)
    {
        WillChange?.Invoke();
        change();
        Changed?.Invoke();
        InvalidateVisual();
    }

    public void Select(ISpan? span)
    {
        Selected = span;
        SelectionChanged?.Invoke(span);
        InvalidateVisual();
    }
}

using SkiaSharp;

namespace PaolaScreenStudio.Core;

/// <summary>Draws one output frame: background, rounded and shadowed recording with zoom, click rings and camera bubble.</summary>
public sealed class FrameRenderer : IDisposable
{
    private readonly EditSettings settings;
    private readonly int outW;
    private readonly int outH;
    private readonly int sourceW;
    private readonly int sourceH;
    private readonly Box content;
    private readonly float corner;
    private readonly CursorPath cursor;
    private readonly ClickEvent[] clicks;
    private readonly SKPaint imagePaint = new() { FilterQuality = SKFilterQuality.High, IsAntialias = true };
    private readonly SKPaint backgroundPaint = new() { IsAntialias = true };
    private readonly SKPaint shadowPaint = new() { IsAntialias = true };

    public FrameRenderer(EditSettings settings, RecordingInfo recording, int sourceW, int sourceH, int outW, int outH)
    {
        this.settings = settings;
        this.outW = outW;
        this.outH = outH;
        this.sourceW = sourceW;
        this.sourceH = sourceH;
        content = Layout.Content(outW, outH, sourceW, sourceH, settings);
        corner = (float)Layout.CornerRadius(outW, outH, settings);
        // Cursor/clicks are stored in recording pixels; scale if the file has another size.
        var sx = recording.Width > 0 ? (double)sourceW / recording.Width : 1;
        var sy = recording.Height > 0 ? (double)sourceH / recording.Height : 1;
        cursor = new CursorPath(recording.Cursor.Select(c => new CursorSample { T = c.T, X = c.X * sx, Y = c.Y * sy }), sourceW, sourceH);
        clicks = recording.Clicks.Select(c => new ClickEvent { T = c.T, X = c.X * sx, Y = c.Y * sy }).OrderBy(c => c.T).ToArray();

        var shortSide = Math.Min(outW, outH);
        switch (settings.Background)
        {
            case BackgroundKind.Gradient:
                var g = settings.Gradient;
                backgroundPaint.Shader = SKShader.CreateLinearGradient(
                    new SKPoint(0, 0), new SKPoint(outW, outH),
                    new[] { ToSk(g.Start), ToSk(g.End) }, SKShaderTileMode.Clamp);
                break;
            case BackgroundKind.Color:
                backgroundPaint.Color = ToSk(settings.BackgroundColor);
                break;
            default:
                backgroundPaint.Color = SKColors.Black;
                break;
        }
        shadowPaint.Color = new SKColor(0, 0, 0, (byte)(Math.Clamp(settings.Shadow, 0, 1) * 150));
        shadowPaint.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, (float)(shortSide * 0.02));
    }

    public CursorPath Cursor => cursor;

    public void Render(SKCanvas canvas, SKBitmap screen, SKBitmap? camera, double t)
    {
        canvas.Clear(SKColors.Black);
        canvas.DrawRect(0, 0, outW, outH, backgroundPaint);

        var rect = new SKRect((float)content.X, (float)content.Y, (float)content.Right, (float)content.Bottom);
        var rounded = new SKRoundRect(rect, corner, corner);
        if (settings.Background != BackgroundKind.None && settings.Shadow > 0)
        {
            canvas.Save();
            canvas.Translate(0, (float)(Math.Min(outW, outH) * 0.008));
            canvas.DrawRoundRect(rounded, shadowPaint);
            canvas.Restore();
        }

        var zoom = ZoomPlanner.At(t, settings.Zooms, cursor);
        var (zx, zy, zw, zh) = zoom.SourceRect;
        var source = new SKRect((float)(zx * sourceW), (float)(zy * sourceH), (float)((zx + zw) * sourceW), (float)((zy + zh) * sourceH));

        canvas.Save();
        canvas.ClipRoundRect(rounded, SKClipOperation.Intersect, true);
        canvas.DrawBitmap(screen, source, rect, imagePaint);
        if (settings.ShowClicks)
        {
            DrawClicks(canvas, t, zx, zy, zw, zh);
        }
        canvas.Restore();

        if (camera != null && settings.ShowCamera)
        {
            DrawCamera(canvas, camera);
        }
    }

    private void DrawClicks(SKCanvas canvas, double t, double zx, double zy, double zw, double zh)
    {
        const double life = 0.6;
        using var paint = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke };
        foreach (var click in clicks)
        {
            if (click.T > t)
            {
                break;
            }
            var age = t - click.T;
            if (age > life)
            {
                continue;
            }
            var p = age / life;
            var u = (click.X / sourceW - zx) / zw;
            var v = (click.Y / sourceH - zy) / zh;
            var x = content.X + u * content.W;
            var y = content.Y + v * content.H;
            var unit = content.W / 1000 * Math.Sqrt(1 / zw);
            paint.StrokeWidth = (float)(4 * unit);
            paint.Color = new SKColor(255, 255, 255, (byte)(220 * (1 - p)));
            canvas.DrawCircle((float)x, (float)y, (float)((10 + 34 * p) * unit), paint);
        }
    }

    private void DrawCamera(SKCanvas canvas, SKBitmap camera)
    {
        var box = Layout.Camera(outW, outH, settings);
        var half = box.W / 2;
        var radius = (float)Layout.ShapeRadius(settings.CameraShape, half);
        var rect = new SKRect((float)box.X, (float)box.Y, (float)box.Right, (float)box.Bottom);
        var rounded = new SKRoundRect(rect, radius, radius);

        using (var shadow = new SKPaint
        {
            IsAntialias = true,
            Color = new SKColor(0, 0, 0, 90),
            MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, (float)(half * 0.12)),
        })
        {
            canvas.Save();
            canvas.Translate(0, (float)(half * 0.06));
            canvas.DrawRoundRect(rounded, shadow);
            canvas.Restore();
        }

        var side = Math.Min(camera.Width, camera.Height);
        var crop = new SKRect((camera.Width - side) / 2f, (camera.Height - side) / 2f, (camera.Width + side) / 2f, (camera.Height + side) / 2f);
        canvas.Save();
        canvas.ClipRoundRect(rounded, SKClipOperation.Intersect, true);
        if (settings.MirrorCamera)
        {
            canvas.Scale(-1, 1, rect.MidX, rect.MidY);
        }
        canvas.DrawBitmap(camera, crop, rect, imagePaint);
        canvas.Restore();

        var border = settings.CameraBorderColor;
        if (border.A > 0)
        {
            var width = (float)Layout.BorderWidth(half);
            using var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = width, Color = ToSk(border) };
            var outer = new SKRoundRect(SKRect.Inflate(rect, width / 2, width / 2), radius + width / 2, radius + width / 2);
            canvas.DrawRoundRect(outer, stroke);
        }
    }

    public static SKColor ToSk(Rgba c) => new(c.R, c.G, c.B, c.A);

    public void Dispose()
    {
        imagePaint.Dispose();
        backgroundPaint.Dispose();
        shadowPaint.Dispose();
    }
}

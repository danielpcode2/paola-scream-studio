using System.Text.RegularExpressions;
using PaolaScreenStudio.Core;
using SkiaSharp;
using Xunit;

namespace PaolaScreenStudio.Core.Tests;

public class TimeMapTests
{
    [Fact]
    public void TrimAndCutsAreRemoved()
    {
        var settings = new EditSettings { TrimStart = 1, TrimEnd = 9 };
        settings.Cuts.Add(new CutSegment { Start = 3, End = 4 });
        settings.Cuts.Add(new CutSegment { Start = 6, End = 6.5 });
        var map = new TimeMap(10, settings);

        Assert.Equal(new[] { (1.0, 3.0), (4.0, 6.0), (6.5, 9.0) }, map.Kept);
        Assert.Equal(6.5, map.OutputDuration, 6);
        Assert.False(map.IsKept(3.5));
        Assert.Equal(4.0, map.NextKept(3.2));
        Assert.Null(map.NextKept(9.5));
        Assert.Equal(2.5, map.ToOutput(4.5), 6);
        Assert.Equal(4.5, map.ToSource(2.5), 6);
    }

    [Fact]
    public void OverlappingCutsDoNotDoubleCount()
    {
        var settings = new EditSettings();
        settings.Cuts.Add(new CutSegment { Start = 2, End = 5 });
        settings.Cuts.Add(new CutSegment { Start = 4, End = 6 });
        var map = new TimeMap(10, settings);
        Assert.Equal(6, map.OutputDuration, 6);
    }
}

public class ZoomTests
{
    [Fact]
    public void ClicksCloseTogetherMakeOneZoom()
    {
        var clicks = new[] { 1.0, 1.8, 2.5, 10.0 }.Select(t => new ClickEvent { T = t, X = 100, Y = 100 });
        var zooms = ZoomPlanner.Auto(clicks, 20, 2);
        Assert.Equal(2, zooms.Count);
        Assert.Equal(0.5, zooms[0].Start, 6);
        Assert.Equal(4.5, zooms[0].End, 6);
        Assert.Equal(9.5, zooms[1].Start, 6);
    }

    [Fact]
    public void ZoomRampsInAndStaysInsideTheFrame()
    {
        var segment = new ZoomSegment { Start = 1, End = 5, Scale = 2, FocusX = 0.95, FocusY = 0.05 };
        var cursor = new CursorPath(Array.Empty<CursorSample>(), 100, 100);
        Assert.Equal(ZoomState.None, ZoomPlanner.At(0.5, new[] { segment }, cursor));
        var full = ZoomPlanner.At(3, new[] { segment }, cursor);
        Assert.Equal(2, full.Scale, 6);
        Assert.Equal(0.75, full.CenterX, 6); // clamped so the right edge stays inside
        Assert.Equal(0.25, full.CenterY, 6);
        var ramping = ZoomPlanner.At(1.1, new[] { segment }, cursor);
        Assert.InRange(ramping.Scale, 1.0001, 1.9999);
    }

    [Fact]
    public void SpansNeverOverlap()
    {
        var a = new ZoomSegment { Start = 0, End = 2 };
        var b = new ZoomSegment { Start = 3, End = 5 };
        var spans = new List<ZoomSegment> { a, b };
        SpanEditing.Move(spans, b, 1, 10);
        Assert.Equal(2, b.Start, 6);
        SpanEditing.ResizeEnd(spans, a, 4, 10);
        Assert.Equal(2, a.End, 6);
        Assert.Null(SpanEditing.FreeSlot(spans, 1, 2, 10));
        Assert.Equal((4.5, 7.0), SpanEditing.FreeSlot(spans, 4.5, 2.5, 10) is (double s, double e) ? (s, e) : (0, 0));
    }
}

public class StoreAndParsingTests
{
    [Fact]
    public void ProjectRoundTripsWithReadableEnums()
    {
        var folder = Directory.CreateTempSubdirectory().FullName;
        var project = new Project { Name = "demo" };
        project.Settings.CameraShape = CameraShape.Rounded;
        project.Settings.CameraBorderColor = new Rgba(139, 92, 246);
        project.Settings.Zooms.Add(new ZoomSegment { Start = 1, End = 2, FocusX = 0.3, FocusY = 0.4 });
        ProjectStore.Save(folder, project);

        Assert.Contains("\"cameraShape\": \"Rounded\"", File.ReadAllText(Path.Combine(folder, "project.json")));
        var loaded = ProjectStore.Load(folder);
        Assert.Equal(CameraShape.Rounded, loaded.Settings.CameraShape);
        Assert.Equal(new Rgba(139, 92, 246), loaded.Settings.CameraBorderColor);
        Assert.Equal(0.3, loaded.Settings.Zooms[0].FocusX);
        Directory.Delete(folder, true);
    }

    [Fact]
    public void ParsesDirectShowDevicesOldAndNewFormat()
    {
        const string modern = """
            [in#0 @ 000001] "Integrated Camera" (video)
            [in#0 @ 000001]   Alternative name "@device_pnp_\\?\usb#vid"
            [in#0 @ 000001] "Microphone Array (Realtek(R) Audio)" (audio)
            """;
        const string legacy = """
            [dshow @ 0001] DirectShow video devices (some may be both video and audio devices)
            [dshow @ 0001]  "Logitech BRIO"
            [dshow @ 0001] DirectShow audio devices
            [dshow @ 0001]  "Headset (Jabra)"
            """;
        var a = Ffmpeg.ParseDevices(modern);
        Assert.Equal(new[] { "Integrated Camera" }, a.Video);
        Assert.Equal(new[] { "Microphone Array (Realtek(R) Audio)" }, a.Audio);
        var b = Ffmpeg.ParseDevices(legacy);
        Assert.Equal(new[] { "Logitech BRIO" }, b.Video);
        Assert.Equal(new[] { "Headset (Jabra)" }, b.Audio);
    }

    [Fact]
    public void EveryTextUsedByTheAppExistsInBothLanguages()
    {
        var src = FindSourceRoot();
        var used = new HashSet<string>();
        foreach (var file in Directory.EnumerateFiles(src, "*.cs", SearchOption.AllDirectories))
        {
            if (file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}"))
            {
                continue;
            }
            foreach (Match match in Regex.Matches(File.ReadAllText(file), "T\\(\"([a-z_.]+)\""))
            {
                used.Add(match.Groups[1].Value);
            }
        }
        // Keys built at runtime.
        foreach (var key in new[] { "small", "medium", "large", "xlarge" })
        {
            used.Add("bubble.size." + key);
        }
        foreach (var shape in Enum.GetValues<CameraShape>())
        {
            used.Add("camera.shape." + shape.ToString().ToLowerInvariant());
        }
        foreach (var key in new[] { "white", "black", "purple", "blue", "green", "orange", "pink", "none" })
        {
            used.Add("camera.border." + key);
        }
        used.RemoveWhere(k => k.EndsWith('.'));
        var missing = used.Where(k => !Strings.Table.ContainsKey(k)).ToList();
        Assert.True(missing.Count == 0, "Missing texts: " + string.Join(", ", missing));
        Assert.All(Strings.Table, pair => Assert.False(string.IsNullOrWhiteSpace(pair.Value.Es) || string.IsNullOrWhiteSpace(pair.Value.En), pair.Key));
    }

    private static string FindSourceRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "src", "PaolaScreenStudio")))
        {
            dir = dir.Parent;
        }
        return Path.Combine(dir?.FullName ?? throw new DirectoryNotFoundException("src"), "src");
    }
}

public class RendererTests
{
    [Fact]
    public void DrawsBackgroundRoundedContentAndCamera()
    {
        var settings = new EditSettings { Background = BackgroundKind.Color, BackgroundColor = new Rgba(255, 0, 0), Padding = 0.1, Shadow = 0 };
        var recording = new RecordingInfo { Width = 160, Height = 90 };
        using var renderer = new FrameRenderer(settings, recording, 160, 90, 320, 180);
        using var screen = new SKBitmap(160, 90, SKColorType.Bgra8888, SKAlphaType.Premul);
        screen.Erase(new SKColor(0, 255, 0));
        using var camera = new SKBitmap(64, 48, SKColorType.Bgra8888, SKAlphaType.Premul);
        camera.Erase(new SKColor(0, 0, 255));
        using var output = new SKBitmap(320, 180, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var canvas = new SKCanvas(output);
        renderer.Render(canvas, screen, camera, 0);
        canvas.Flush();

        Assert.Equal(new SKColor(255, 0, 0), output.GetPixel(2, 2));        // background
        Assert.Equal(new SKColor(0, 255, 0), output.GetPixel(160, 60));     // recording
        var bubble = Layout.Camera(320, 180, settings);
        Assert.Equal(new SKColor(0, 0, 255), output.GetPixel((int)bubble.CenterX, (int)bubble.CenterY)); // camera
    }
}

/// <summary>Real ffmpeg runs (skipped when ffmpeg is not installed).</summary>
public class FfmpegIntegrationTests
{
    private static Ffmpeg? Tool => Ffmpeg.Locate(null);

    private static async Task MakeClip(Ffmpeg ffmpeg, string path, double seconds, bool audio, int w = 320, int h = 180)
    {
        var args = new List<string> { "-y", "-v", "error", "-f", "lavfi", "-i", $"testsrc2=size={w}x{h}:rate=30:duration={Ffmpeg.F(seconds)}" };
        if (audio)
        {
            args.AddRange(new[] { "-f", "lavfi", "-i", $"sine=frequency=440:duration={Ffmpeg.F(seconds)}" });
        }
        args.AddRange(new[] { "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p" });
        if (audio)
        {
            args.AddRange(new[] { "-c:a", "aac" });
        }
        args.Add(path);
        await ffmpeg.RunAsync(args);
    }

    [Fact]
    public async Task JoinsSegmentsWithMicAndSystemAudio()
    {
        if (Tool is not Ffmpeg ffmpeg)
        {
            return;
        }
        var folder = Directory.CreateTempSubdirectory().FullName;
        var s1 = Path.Combine(folder, "screen-1.mkv");
        var s2 = Path.Combine(folder, "screen-2.mkv");
        var sys = Path.Combine(folder, "system-1.wav");
        var c1 = Path.Combine(folder, "camera-1.mkv");
        var c2 = Path.Combine(folder, "camera-2.mkv");
        await MakeClip(ffmpeg, s1, 2, audio: true);
        await MakeClip(ffmpeg, s2, 1.5, audio: false);
        await MakeClip(ffmpeg, c1, 2, audio: false, 160, 120);
        await MakeClip(ffmpeg, c2, 1.5, audio: false, 160, 120);
        await ffmpeg.RunAsync(new[] { "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=220:duration=1.5", sys });

        var result = await RecordingFinalizer.FinalizeAsync(ffmpeg, folder, new[]
        {
            new SegmentFiles { Screen = s1, SystemAudio = sys, Camera = c1 },
            new SegmentFiles { Screen = s2, Camera = c2 },
        });

        var info = await ffmpeg.ProbeAsync(Path.Combine(folder, RecordingFinalizer.ScreenFile));
        Assert.True(info.HasAudio);
        Assert.Equal(320, info.Width);
        Assert.InRange(info.Duration, 3.3, 3.8);
        Assert.True(result.HasCamera);
        var camera = await ffmpeg.ProbeAsync(Path.Combine(folder, RecordingFinalizer.CameraFile));
        Assert.InRange(camera.Duration, 3.3, 3.8);
        Directory.Delete(folder, true);
    }

    [Fact]
    public async Task ExportsEditedVideoAndGif()
    {
        if (Tool is not Ffmpeg ffmpeg)
        {
            return;
        }
        var folder = Directory.CreateTempSubdirectory().FullName;
        await MakeClip(ffmpeg, Path.Combine(folder, "recording.mp4"), 4, audio: true, 640, 360);
        await MakeClip(ffmpeg, Path.Combine(folder, "camera.mp4"), 4, audio: false, 320, 240);
        var project = new Project
        {
            Recording = new RecordingInfo
            {
                Width = 640, Height = 360, Duration = 4, CameraFile = "camera.mp4",
                Cursor = { new CursorSample { T = 0, X = 100, Y = 100 }, new CursorSample { T = 4, X = 500, Y = 300 } },
                Clicks = { new ClickEvent { T = 1, X = 120, Y = 110 } },
            },
        };
        project.Settings.Zooms.Add(new ZoomSegment { Start = 0.5, End = 2.5, Scale = 2 });
        project.Settings.Cuts.Add(new CutSegment { Start = 3, End = 3.5 });
        project.Settings.CameraShape = CameraShape.Rounded;

        var mp4 = Path.Combine(folder, "out.mp4");
        var reports = new List<double>();
        await Exporter.ExportAsync(ffmpeg, folder, project, new ExportOptions { Height = 360, Fps = 30 }, mp4, new SyncProgress(reports.Add));
        var info = await ffmpeg.ProbeAsync(mp4);
        Assert.Equal(640, info.Width);
        Assert.Equal(360, info.Height);
        Assert.True(info.HasAudio);
        Assert.InRange(info.Duration, 3.3, 3.7); // 4 s minus a 0.5 s cut
        Assert.Equal(1, reports.Last());

        var gif = Path.Combine(folder, "out.gif");
        await Exporter.ExportAsync(ffmpeg, folder, project, new ExportOptions { Height = 360, Format = ExportFormat.Gif }, gif);
        Assert.True(new FileInfo(gif).Length > 1000);
        Directory.Delete(folder, true);
    }

    private sealed class SyncProgress : IProgress<double>
    {
        private readonly Action<double> report;

        public SyncProgress(Action<double> report) => this.report = report;

        public void Report(double value) => report(value);
    }
}

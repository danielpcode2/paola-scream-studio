using System.Diagnostics;
using System.IO;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

public sealed class RecordingRequest
{
    public CaptureMode Mode { get; init; }
    /// <summary>Captured area in physical pixels (display, window bounds or selected area).</summary>
    public ScreenRect Area { get; init; }
    /// <summary>Window title for window capture (ffmpeg follows the window).</summary>
    public string? WindowTitle { get; init; }
    public string? Microphone { get; init; }
    public string? Camera { get; init; }
    public bool SystemAudio { get; init; }
}

/// <summary>
/// One recording: ffmpeg (gdigrab) for the screen + microphone, a second ffmpeg for the camera
/// (also streaming JPEG previews for the bubble), WASAPI loopback for system audio, and the mouse.
/// Pausing ends the current segment; resuming starts a new one. Finish joins everything.
/// </summary>
public sealed class RecordingSession : IDisposable
{
    private readonly Ffmpeg ffmpeg;
    private readonly RecordingRequest request;
    private readonly List<SegmentFiles> segments = new();
    private readonly List<(double Start, double Clock)> segmentClocks = new();
    private readonly List<CursorSample> cursor = new();
    private readonly List<ClickEvent> clicks = new();
    private readonly Stopwatch clock = new();
    private readonly MouseTracker mouse;
    private Process? screenProcess;
    private Process? cameraProcess;
    private StderrTail? screenErrors;
    private WasapiLoopbackCapture? loopback;
    private WasapiOut? silence;
    private double segmentStart;

    public string Folder { get; }
    public bool IsPaused { get; private set; }
    public TimeSpan Elapsed => clock.Elapsed;

    /// <summary>JPEG frames from the camera for the live bubble (raised on a background thread).</summary>
    public event Action<byte[]>? CameraFrame;

    public RecordingSession(Ffmpeg ffmpeg, RecordingRequest request, string projectsDirectory)
    {
        this.ffmpeg = ffmpeg;
        this.request = request;
        Folder = ProjectStore.CreateFolder(projectsDirectory, DateTime.Now);
        mouse = new MouseTracker(request.Area, Sample, Click);
    }

    public async Task StartAsync()
    {
        await StartSegmentAsync();
        mouse.Start();
    }

    public async Task PauseAsync()
    {
        if (IsPaused)
        {
            return;
        }
        IsPaused = true;
        await StopSegmentAsync();
    }

    public async Task ResumeAsync()
    {
        if (!IsPaused)
        {
            return;
        }
        IsPaused = false;
        await StartSegmentAsync();
    }

    /// <summary>Stops capture, joins the segments and writes project.json. Returns the project folder.</summary>
    public async Task<string> FinishAsync(EditSettings baseSettings, CancellationToken ct = default)
    {
        mouse.Stop();
        if (!IsPaused)
        {
            await StopSegmentAsync();
        }
        var result = await RecordingFinalizer.FinalizeAsync(ffmpeg, Folder, segments, ct);

        // ffmpeg starts capturing a moment after launch: align mouse times with each segment's video.
        var samples = new List<CursorSample>();
        var events = new List<ClickEvent>();
        var videoStart = 0.0;
        for (var i = 0; i < segmentClocks.Count && i < result.SegmentDurations.Count; i++)
        {
            var (start, length) = segmentClocks[i];
            var video = result.SegmentDurations[i];
            var lag = Math.Max(0, length - video);
            var end = start + length;
            foreach (var s in cursor.Where(s => s.T >= start && s.T < end))
            {
                var t = videoStart + s.T - start - lag;
                if (t >= 0)
                {
                    samples.Add(new CursorSample { T = t, X = s.X, Y = s.Y });
                }
            }
            foreach (var c in clicks.Where(c => c.T >= start && c.T < end))
            {
                var t = videoStart + c.T - start - lag;
                if (t >= 0)
                {
                    events.Add(new ClickEvent { T = t, X = c.X, Y = c.Y });
                }
            }
            videoStart += video;
        }

        var settings = baseSettings;
        settings.Zooms = ZoomPlanner.Auto(events, result.Duration, settings.AutoZoomScale);
        var cameraOffset = 0.0;
        if (result.HasCamera && result.CameraDurations.Count > 0 && segmentClocks.Count > 0)
        {
            // Camera time = screen time - offset; each process lags differently behind the clock.
            var screenLag = Math.Max(0, segmentClocks[0].Clock - result.SegmentDurations[0]);
            var cameraLag = Math.Max(0, segmentClocks[0].Clock - result.CameraDurations[0]);
            cameraOffset = cameraLag - screenLag;
        }
        var project = new Project
        {
            Name = Path.GetFileName(Folder),
            CreatedAt = DateTime.Now,
            Recording = new RecordingInfo
            {
                ScreenFile = RecordingFinalizer.ScreenFile,
                CameraFile = result.HasCamera ? RecordingFinalizer.CameraFile : null,
                Width = result.Width,
                Height = result.Height,
                Duration = result.Duration,
                CameraOffset = cameraOffset,
                Cursor = samples,
                Clicks = events,
            },
            Settings = settings,
        };
        ProjectStore.Save(Folder, project);
        DeleteSegments();
        return Folder;
    }

    /// <summary>Stops everything and deletes the project folder.</summary>
    public async Task CancelAsync()
    {
        mouse.Stop();
        if (!IsPaused)
        {
            await StopSegmentAsync();
        }
        try
        {
            Directory.Delete(Folder, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private async Task StartSegmentAsync()
    {
        var n = segments.Count + 1;
        var segment = new SegmentFiles { Screen = Path.Combine(Folder, $"screen-{n}.mkv") };
        var area = request.Area.Even();

        var args = new List<string> { "-y", "-hide_banner", "-loglevel", "error", "-thread_queue_size", "1024",
            "-f", "gdigrab", "-framerate", "60", "-draw_mouse", "1" };
        if (request.Mode == CaptureMode.Window && request.WindowTitle != null)
        {
            args.AddRange(new[] { "-i", "title=" + request.WindowTitle });
        }
        else
        {
            args.AddRange(new[] { "-offset_x", area.X.ToString(), "-offset_y", area.Y.ToString(),
                "-video_size", $"{area.Width}x{area.Height}", "-i", "desktop" });
        }
        if (request.Microphone != null)
        {
            args.AddRange(new[] { "-thread_queue_size", "1024", "-rtbufsize", "64M", "-f", "dshow", "-i", "audio=" + request.Microphone,
                "-map", "0:v", "-map", "1:a", "-c:a", "aac", "-b:a", "160k" });
        }
        args.AddRange(new[] { "-vf", "crop=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-preset", "ultrafast",
            "-crf", "18", "-pix_fmt", "yuv420p", segment.Screen });

        if (request.Camera != null)
        {
            segment.Camera = Path.Combine(Folder, $"camera-{n}.mkv");
            cameraProcess = ffmpeg.Start(new[]
            {
                "-y", "-hide_banner", "-loglevel", "error", "-rtbufsize", "256M", "-f", "dshow", "-i", "video=" + request.Camera,
                "-map", "0:v", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-pix_fmt", "yuv420p", segment.Camera,
                "-map", "0:v", "-vf", "fps=20,scale=360:-2", "-f", "mjpeg", "-q:v", "6", "pipe:1",
            }, redirectInput: true, redirectOutput: true);
            new StderrTail().Attach(cameraProcess);
            var stream = cameraProcess.StandardOutput.BaseStream;
            _ = Task.Run(() => ReadJpegs(stream));
        }

        if (request.SystemAudio)
        {
            segment.SystemAudio = Path.Combine(Folder, $"system-{n}.wav");
            StartLoopback(segment.SystemAudio);
        }

        screenProcess = ffmpeg.Start(args, redirectInput: true);
        screenErrors = new StderrTail();
        screenErrors.Attach(screenProcess);
        segments.Add(segment);
        segmentStart = clock.Elapsed.TotalSeconds;
        clock.Start();

        // Fail fast when ffmpeg cannot open the screen, window or microphone.
        await Task.Delay(700);
        if (screenProcess.HasExited)
        {
            var message = screenErrors.ToString();
            await StopSegmentAsync();
            segments.Remove(segment);
            throw new FfmpegException(string.IsNullOrWhiteSpace(message) ? Strings.T("error.capture_failed") : message);
        }
    }

    private async Task StopSegmentAsync()
    {
        clock.Stop();
        segmentClocks.Add((segmentStart, clock.Elapsed.TotalSeconds - segmentStart));
        await StopLoopbackAsync();
        await StopProcessAsync(screenProcess);
        await StopProcessAsync(cameraProcess);
        screenProcess = null;
        cameraProcess = null;
    }

    /// <summary>"q" asks ffmpeg to finish the file cleanly; kill only if it does not exit.</summary>
    private static async Task StopProcessAsync(Process? process)
    {
        if (process == null)
        {
            return;
        }
        try
        {
            if (!process.HasExited)
            {
                await process.StandardInput.WriteAsync("q");
                await process.StandardInput.FlushAsync();
            }
        }
        catch (IOException)
        {
        }
        var exited = process.WaitForExitAsync();
        if (await Task.WhenAny(exited, Task.Delay(8000)) != exited)
        {
            Ffmpeg.TryKill(process);
        }
        process.Dispose();
    }

    private void StartLoopback(string path)
    {
        var capture = new WasapiLoopbackCapture();
        var writer = new WaveFileWriter(path, capture.WaveFormat);
        var gate = new object();
        var closed = false;
        capture.DataAvailable += (_, e) =>
        {
            lock (gate)
            {
                if (!closed)
                {
                    writer.Write(e.Buffer, 0, e.BytesRecorded);
                }
            }
        };
        capture.RecordingStopped += (_, _) =>
        {
            lock (gate)
            {
                closed = true;
                writer.Dispose();
            }
        };
        loopback = capture;
        // Loopback delivers nothing while the system is silent; playing silence keeps the timing continuous.
        silence = new WasapiOut(AudioClientShareMode.Shared, 100);
        silence.Init(new SilenceProvider(new WaveFormat(48000, 16, 2)).ToSampleProvider());
        silence.Play();
        capture.StartRecording();
    }

    /// <summary>
    /// Stops system audio. NAudio raises RecordingStopped (which closes the WAV) on the UI thread,
    /// so wait asynchronously instead of blocking it.
    /// </summary>
    private async Task StopLoopbackAsync()
    {
        if (loopback != null)
        {
            var capture = loopback;
            loopback = null;
            var stopped = new TaskCompletionSource();
            capture.RecordingStopped += (_, _) => stopped.TrySetResult();
            capture.StopRecording();
            await Task.WhenAny(stopped.Task, Task.Delay(3000));
            capture.Dispose();
        }
        silence?.Stop();
        silence?.Dispose();
        silence = null;
    }

    private void ReadJpegs(Stream stream)
    {
        var buffer = new byte[1 << 16];
        var frame = new MemoryStream();
        var previous = -1;
        var inFrame = false;
        try
        {
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                for (var i = 0; i < read; i++)
                {
                    var b = buffer[i];
                    if (!inFrame)
                    {
                        if (previous == 0xFF && b == 0xD8)
                        {
                            inFrame = true;
                            frame.SetLength(0);
                            frame.WriteByte(0xFF);
                            frame.WriteByte(0xD8);
                        }
                    }
                    else
                    {
                        frame.WriteByte(b);
                        if (previous == 0xFF && b == 0xD9)
                        {
                            inFrame = false;
                            CameraFrame?.Invoke(frame.ToArray());
                        }
                    }
                    previous = b;
                }
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void Sample(double x, double y)
    {
        if (!IsPaused && clock.IsRunning)
        {
            cursor.Add(new CursorSample { T = clock.Elapsed.TotalSeconds, X = x, Y = y });
        }
    }

    private void Click(double x, double y)
    {
        if (!IsPaused && clock.IsRunning && x >= 0 && y >= 0 && x <= request.Area.Width && y <= request.Area.Height)
        {
            clicks.Add(new ClickEvent { T = clock.Elapsed.TotalSeconds, X = x, Y = y });
        }
    }

    private void DeleteSegments()
    {
        foreach (var segment in segments)
        {
            foreach (var file in new[] { segment.Screen, segment.SystemAudio, segment.Camera })
            {
                if (file != null && File.Exists(file))
                {
                    try
                    {
                        File.Delete(file);
                    }
                    catch (IOException)
                    {
                    }
                }
            }
        }
    }

    public void Dispose()
    {
        mouse.Stop();
        loopback?.StopRecording();
        silence?.Dispose();
        if (screenProcess != null)
        {
            Ffmpeg.TryKill(screenProcess);
        }
        if (cameraProcess != null)
        {
            Ffmpeg.TryKill(cameraProcess);
        }
    }
}

/// <summary>Cursor position at 60 Hz and clicks (low-level mouse hook), relative to the captured area.</summary>
internal sealed class MouseTracker
{
    private readonly ScreenRect area;
    private readonly Action<double, double> sample;
    private readonly Action<double, double> click;
    private readonly System.Windows.Threading.DispatcherTimer timer;
    private readonly Native.HookProc hookProc;
    private IntPtr hook;

    public MouseTracker(ScreenRect area, Action<double, double> sample, Action<double, double> click)
    {
        this.area = area;
        this.sample = sample;
        this.click = click;
        hookProc = OnHook;
        timer = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(1000.0 / 60),
        };
        timer.Tick += (_, _) =>
        {
            if (Native.GetCursorPos(out var p))
            {
                sample(p.X - area.X, p.Y - area.Y);
            }
        };
    }

    public void Start()
    {
        timer.Start();
        hook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, hookProc, Native.GetModuleHandle(null), 0);
    }

    public void Stop()
    {
        timer.Stop();
        if (hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
    }

    private IntPtr OnHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam == Native.WM_LBUTTONDOWN || wParam == Native.WM_RBUTTONDOWN))
        {
            var data = System.Runtime.InteropServices.Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
            click(data.pt.X - area.X, data.pt.Y - area.Y);
        }
        return Native.CallNextHookEx(hook, code, wParam, lParam);
    }
}

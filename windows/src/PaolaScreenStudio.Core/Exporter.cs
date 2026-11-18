using System.Diagnostics;
using SkiaSharp;
using static PaolaScreenStudio.Core.Ffmpeg;

namespace PaolaScreenStudio.Core;

/// <summary>
/// Renders the edited video: ffmpeg decodes raw frames, <see cref="FrameRenderer"/> composes each one
/// and a second ffmpeg encodes them. Cut and trimmed frames are skipped; audio is cut the same way.
/// </summary>
public static class Exporter
{
    public static async Task ExportAsync(
        Ffmpeg ffmpeg, string folder, Project project, ExportOptions options, string output,
        IProgress<double>? progress = null, CancellationToken ct = default)
    {
        var screenPath = Path.Combine(folder, project.Recording.ScreenFile);
        var info = await ffmpeg.ProbeAsync(screenPath, ct);
        if (!info.HasVideo || info.Width <= 0)
        {
            throw new FfmpegException(Strings.T("error.empty_recording"));
        }
        var map = new TimeMap(info.Duration, project.Settings);
        if (map.OutputDuration < 0.1)
        {
            throw new FfmpegException(Strings.T("error.nothing_to_export"));
        }
        var fps = Math.Clamp(options.Format == ExportFormat.Gif ? Math.Min(options.Fps, 15) : options.Fps, 1, 120);
        var targetH = options.Format == ExportFormat.Gif ? Math.Min(options.Height, 720) : options.Height;
        var (outW, outH) = Layout.OutputSize(info.Width, info.Height, targetH);

        var temp = Path.Combine(Path.GetTempPath(), "paola-export-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            string? audio = null;
            if (info.HasAudio && options.Format == ExportFormat.Mp4)
            {
                audio = Path.Combine(temp, "audio.m4a");
                await ffmpeg.RunAsync(AudioArgs(screenPath, map, audio), ct);
            }
            var videoTarget = options.Format == ExportFormat.Gif ? Path.Combine(temp, "video.mp4") : output;
            await RenderVideoAsync(ffmpeg, folder, project, info, map, fps, outW, outH, options.Quality, audio, videoTarget, progress, ct);
            if (options.Format == ExportFormat.Gif)
            {
                await ffmpeg.RunAsync(new[]
                {
                    "-y", "-hide_banner", "-v", "error", "-i", videoTarget,
                    "-vf", "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                    "-loop", "0", output,
                }, ct);
            }
            progress?.Report(1);
        }
        finally
        {
            try
            {
                Directory.Delete(temp, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    public static List<string> AudioArgs(string input, TimeMap map, string output)
    {
        var filters = new List<string>();
        var inputs = "";
        for (var i = 0; i < map.Kept.Count; i++)
        {
            var (start, end) = map.Kept[i];
            filters.Add($"[0:a]atrim={F(start)}:{F(end)},asetpts=PTS-STARTPTS[a{i}]");
            inputs += $"[a{i}]";
        }
        filters.Add($"{inputs}concat=n={map.Kept.Count}:v=0:a=1[a]");
        return new List<string>
        {
            "-y", "-hide_banner", "-v", "error", "-i", input,
            "-filter_complex", string.Join(";", filters), "-map", "[a]", "-c:a", "aac", "-b:a", "192k", output,
        };
    }

    private static async Task RenderVideoAsync(
        Ffmpeg ffmpeg, string folder, Project project, MediaInfo info, TimeMap map, int fps, int outW, int outH,
        ExportQuality quality, string? audio, string output, IProgress<double>? progress, CancellationToken ct)
    {
        var crf = quality switch { ExportQuality.High => "18", ExportQuality.Medium => "23", _ => "28" };
        var encoderArgs = new List<string>
        {
            "-y", "-hide_banner", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-s", $"{outW}x{outH}", "-framerate", fps.ToString(), "-i", "pipe:0",
        };
        if (audio != null)
        {
            encoderArgs.AddRange(new[] { "-i", audio, "-map", "0:v", "-map", "1:a", "-c:a", "copy", "-shortest" });
        }
        encoderArgs.AddRange(new[] { "-c:v", "libx264", "-preset", "medium", "-crf", crf, "-pix_fmt", "yuv420p", "-movflags", "+faststart", output });

        CameraReader? camera = null;
        var cameraPath = project.Recording.CameraFile is string c ? Path.Combine(folder, c) : null;
        if (project.Settings.ShowCamera && cameraPath != null && File.Exists(cameraPath))
        {
            var cameraInfo = await ffmpeg.ProbeAsync(cameraPath, ct);
            if (cameraInfo.HasVideo && cameraInfo.Width > 0)
            {
                camera = new CameraReader(ffmpeg, cameraPath, cameraInfo, fps, project.Recording.CameraOffset);
            }
        }

        using var decoder = ffmpeg.Start(new[]
        {
            "-hide_banner", "-v", "error", "-i", Path.Combine(folder, project.Recording.ScreenFile),
            "-vf", $"fps={fps}", "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1",
        }, redirectOutput: true);
        var decoderErrors = new StderrTail();
        decoderErrors.Attach(decoder);
        using var encoder = ffmpeg.Start(encoderArgs, redirectInput: true);
        var encoderErrors = new StderrTail();
        encoderErrors.Attach(encoder);

        using var renderer = new FrameRenderer(project.Settings, project.Recording, info.Width, info.Height, outW, outH);
        using var screen = new SKBitmap(new SKImageInfo(info.Width, info.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var frame = new SKBitmap(new SKImageInfo(outW, outH, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var canvas = new SKCanvas(frame);
        var keptFrames = Math.Max(1, (int)(map.OutputDuration * fps));
        var written = 0;
        var input = decoder.StandardOutput.BaseStream;
        var sink = encoder.StandardInput.BaseStream;
        try
        {
            for (var index = 0; ; index++)
            {
                ct.ThrowIfCancellationRequested();
                if (!await ReadFrameAsync(input, screen, ct))
                {
                    break;
                }
                var t = (double)index / fps;
                var cameraFrame = camera != null ? await camera.FrameAtAsync(t, ct) : null;
                if (!map.IsKept(t))
                {
                    continue;
                }
                renderer.Render(canvas, screen, cameraFrame, t);
                canvas.Flush();
                await WriteFrameAsync(sink, frame, ct);
                written++;
                if (written % 15 == 0)
                {
                    progress?.Report(Math.Min(0.99, (double)written / keptFrames));
                }
            }
            sink.Close();
            await encoder.WaitForExitAsync(ct);
            await decoder.WaitForExitAsync(ct);
        }
        catch
        {
            TryKill(encoder);
            TryKill(decoder);
            throw;
        }
        finally
        {
            camera?.Dispose();
        }
        if (encoder.ExitCode != 0)
        {
            throw new FfmpegException(encoderErrors.ToString());
        }
        if (decoder.ExitCode != 0)
        {
            throw new FfmpegException(decoderErrors.ToString());
        }
        if (written == 0)
        {
            throw new FfmpegException(Strings.T("error.nothing_to_export"));
        }
    }

    internal static unsafe Task<bool> ReadFrameAsync(Stream stream, SKBitmap bitmap, CancellationToken ct)
    {
        var length = bitmap.ByteCount;
        var buffer = new UnmanagedMemory(bitmap.GetPixels(), length);
        return ReadExactlyAsync(stream, buffer.Memory, ct);
    }

    private static async Task<bool> ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken ct)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer[total..], ct);
            if (read == 0)
            {
                return false;
            }
            total += read;
        }
        return true;
    }

    private static Task WriteFrameAsync(Stream stream, SKBitmap bitmap, CancellationToken ct)
    {
        var buffer = new UnmanagedMemory(bitmap.GetPixels(), bitmap.ByteCount);
        return stream.WriteAsync(buffer.Memory, ct).AsTask();
    }

    /// <summary>Reads camera frames on demand so they stay aligned with the screen timeline.</summary>
    private sealed class CameraReader : IDisposable
    {
        private readonly Process process;
        private readonly SKBitmap bitmap;
        private readonly int fps;
        private readonly double offset;
        private int nextIndex;
        private bool hasFrame;
        private bool ended;

        public CameraReader(Ffmpeg ffmpeg, string path, MediaInfo info, int fps, double offset)
        {
            this.fps = fps;
            this.offset = offset;
            var height = Math.Min(480, info.Height);
            var width = Layout.Even(height * (double)info.Width / info.Height);
            height = Layout.Even(height);
            process = ffmpeg.Start(new[]
            {
                "-hide_banner", "-v", "error", "-i", path,
                "-vf", $"fps={fps},scale={width}:{height}", "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1",
            }, redirectOutput: true);
            new StderrTail().Attach(process);
            bitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
        }

        public async Task<SKBitmap?> FrameAtAsync(double screenTime, CancellationToken ct)
        {
            var cameraTime = screenTime - offset;
            if (cameraTime < 0)
            {
                return null;
            }
            var wanted = (int)Math.Floor(cameraTime * fps + 1e-6);
            while (!ended && nextIndex <= wanted)
            {
                if (await ReadFrameAsync(process.StandardOutput.BaseStream, bitmap, ct))
                {
                    hasFrame = true;
                    nextIndex++;
                }
                else
                {
                    ended = true;
                }
            }
            return hasFrame ? bitmap : null;
        }

        public void Dispose()
        {
            TryKill(process);
            process.Dispose();
            bitmap.Dispose();
        }
    }
}

/// <summary>Exposes native pixel memory as <see cref="Memory{T}"/> for async stream I/O.</summary>
internal sealed unsafe class UnmanagedMemory : System.Buffers.MemoryManager<byte>
{
    private readonly byte* pointer;
    private readonly int length;

    public UnmanagedMemory(IntPtr pointer, int length)
    {
        this.pointer = (byte*)pointer;
        this.length = length;
    }

    public override Span<byte> GetSpan() => new(pointer, length);

    public override System.Buffers.MemoryHandle Pin(int elementIndex = 0) => new(pointer + elementIndex);

    public override void Unpin()
    {
    }

    protected override void Dispose(bool disposing)
    {
    }
}

using static PaolaScreenStudio.Core.Ffmpeg;

namespace PaolaScreenStudio.Core;

/// <summary>Files written for one recording segment (a new segment starts after each pause).</summary>
public sealed class SegmentFiles
{
    /// <summary>Screen video, with the microphone as its audio stream when a mic was selected.</summary>
    public string Screen { get; set; } = "";
    /// <summary>System audio (WAV) or null.</summary>
    public string? SystemAudio { get; set; }
    public string? Camera { get; set; }
}

public sealed record FinalizedRecording(int Width, int Height, double Duration, IReadOnlyList<double> SegmentDurations, bool HasCamera, IReadOnlyList<double> CameraDurations);

/// <summary>Joins the segments into recording.mp4 (screen + mic + system audio) and camera.mp4.</summary>
public static class RecordingFinalizer
{
    public const string ScreenFile = "recording.mp4";
    public const string CameraFile = "camera.mp4";

    public static async Task<FinalizedRecording> FinalizeAsync(Ffmpeg ffmpeg, string folder, IReadOnlyList<SegmentFiles> segments, CancellationToken ct = default)
    {
        if (segments.Count == 0)
        {
            throw new FfmpegException(Strings.T("error.empty_recording"));
        }
        var infos = new List<MediaInfo>();
        var systemInfos = new List<MediaInfo?>();
        foreach (var segment in segments)
        {
            infos.Add(await ffmpeg.ProbeAsync(segment.Screen, ct));
            systemInfos.Add(segment.SystemAudio != null && File.Exists(segment.SystemAudio) && new FileInfo(segment.SystemAudio).Length > 1024
                ? await ffmpeg.ProbeAsync(segment.SystemAudio, ct)
                : null);
        }
        var width = infos[0].Width;
        var height = infos[0].Height;
        if (width <= 0 || height <= 0)
        {
            throw new FfmpegException(Strings.T("error.empty_recording"));
        }

        await ffmpeg.RunAsync(ScreenArgs(segments, infos, systemInfos, Path.Combine(folder, ScreenFile)), ct);

        var cameraDurations = new List<double>();
        var hasCamera = segments.All(s => s.Camera != null && File.Exists(s.Camera));
        if (hasCamera)
        {
            try
            {
                var cameraInfos = new List<MediaInfo>();
                foreach (var segment in segments)
                {
                    cameraInfos.Add(await ffmpeg.ProbeAsync(segment.Camera!, ct));
                }
                cameraDurations.AddRange(cameraInfos.Select(i => i.Duration));
                await ffmpeg.RunAsync(CameraArgs(segments, cameraInfos[0], Path.Combine(folder, CameraFile)), ct);
            }
            catch (FfmpegException)
            {
                // A broken camera file must not lose the screen recording.
                hasCamera = false;
                cameraDurations.Clear();
            }
        }
        var final = await ffmpeg.ProbeAsync(Path.Combine(folder, ScreenFile), ct);
        return new FinalizedRecording(width, height, final.Duration, infos.Select(i => i.Duration).ToList(), hasCamera, cameraDurations);
    }

    public static List<string> ScreenArgs(IReadOnlyList<SegmentFiles> segments, IReadOnlyList<MediaInfo> infos, IReadOnlyList<MediaInfo?> systemInfos, string output)
    {
        var args = new List<string> { "-y", "-hide_banner", "-v", "error" };
        var screenIndex = new int[segments.Count];
        var systemIndex = new int?[segments.Count];
        var next = 0;
        for (var i = 0; i < segments.Count; i++)
        {
            args.AddRange(new[] { "-i", segments[i].Screen });
            screenIndex[i] = next++;
            if (systemInfos[i] != null)
            {
                args.AddRange(new[] { "-i", segments[i].SystemAudio! });
                systemIndex[i] = next++;
            }
        }
        var width = Layout.Even(infos[0].Width);
        var height = Layout.Even(infos[0].Height);
        var withAudio = infos.Any(i => i.HasAudio) || systemInfos.Any(i => i != null);
        var filters = new List<string>();
        var concatInputs = "";
        for (var i = 0; i < segments.Count; i++)
        {
            var duration = F(infos[i].Duration);
            filters.Add($"[{screenIndex[i]}:v]setpts=PTS-STARTPTS,fps=60,scale={width}:{height},setsar=1,format=yuv420p[v{i}]");
            concatInputs += $"[v{i}]";
            if (!withAudio)
            {
                continue;
            }
            const string normalize = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo";
            var sources = new List<string>();
            if (infos[i].HasAudio)
            {
                filters.Add($"[{screenIndex[i]}:a]{normalize},asetpts=PTS-STARTPTS[mic{i}]");
                sources.Add($"[mic{i}]");
            }
            if (systemIndex[i] is int s)
            {
                filters.Add($"[{s}:a]{normalize},asetpts=PTS-STARTPTS[sys{i}]");
                sources.Add($"[sys{i}]");
            }
            var mixed = sources.Count switch
            {
                0 => "anullsrc=r=48000:cl=stereo,",
                1 => sources[0],
                _ => $"{string.Join("", sources)}amix=inputs={sources.Count}:duration=longest:normalize=0,",
            };
            // Pad or cut so the audio lasts exactly as long as the video of this segment.
            filters.Add($"{mixed}apad,atrim=0:{duration},asetpts=PTS-STARTPTS[a{i}]");
            concatInputs += $"[a{i}]";
        }
        filters.Add($"{concatInputs}concat=n={segments.Count}:v=1:a={(withAudio ? 1 : 0)}[v]{(withAudio ? "[a]" : "")}");
        args.AddRange(new[] { "-filter_complex", string.Join(";", filters), "-map", "[v]" });
        if (withAudio)
        {
            args.AddRange(new[] { "-map", "[a]", "-c:a", "aac", "-b:a", "192k" });
        }
        args.AddRange(new[] { "-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart", output });
        return args;
    }

    public static List<string> CameraArgs(IReadOnlyList<SegmentFiles> segments, MediaInfo first, string output)
    {
        var args = new List<string> { "-y", "-hide_banner", "-v", "error" };
        foreach (var segment in segments)
        {
            args.AddRange(new[] { "-i", segment.Camera! });
        }
        var width = Layout.Even(first.Width);
        var height = Layout.Even(first.Height);
        var filters = new List<string>();
        var inputs = "";
        for (var i = 0; i < segments.Count; i++)
        {
            filters.Add($"[{i}:v]setpts=PTS-STARTPTS,fps=30,scale={width}:{height},setsar=1,format=yuv420p[c{i}]");
            inputs += $"[c{i}]";
        }
        filters.Add($"{inputs}concat=n={segments.Count}:v=1:a=0[v]");
        args.AddRange(new[] { "-filter_complex", string.Join(";", filters), "-map", "[v]", "-an",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-movflags", "+faststart", output });
        return args;
    }
}

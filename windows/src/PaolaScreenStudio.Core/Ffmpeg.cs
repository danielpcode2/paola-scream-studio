using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PaolaScreenStudio.Core;

public sealed record MediaInfo(int Width, int Height, double Duration, bool HasVideo, bool HasAudio);

public sealed record CaptureDevices(IReadOnlyList<string> Video, IReadOnlyList<string> Audio);

public sealed class FfmpegException : Exception
{
    public FfmpegException(string message) : base(message) { }
}

/// <summary>Finds and runs ffmpeg/ffprobe. Arguments are passed as a list (no shell quoting).</summary>
public sealed class Ffmpeg
{
    public string FfmpegPath { get; }
    public string FfprobePath { get; }

    private Ffmpeg(string ffmpeg, string ffprobe)
    {
        FfmpegPath = ffmpeg;
        FfprobePath = ffprobe;
    }

    /// <summary>Configured path, then next to the app, then PATH, then the WinGet links folder.</summary>
    public static Ffmpeg? Locate(string? configured)
    {
        var exe = OperatingSystem.IsWindows() ? ".exe" : "";
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(configured))
        {
            candidates.Add(Directory.Exists(configured) ? Path.Combine(configured, "ffmpeg" + exe) : configured);
        }
        var appDir = AppContext.BaseDirectory;
        candidates.Add(Path.Combine(appDir, "ffmpeg" + exe));
        candidates.Add(Path.Combine(appDir, "ffmpeg", "bin", "ffmpeg" + exe));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(dir.Trim('"'), "ffmpeg" + exe));
        }
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrEmpty(localAppData))
        {
            candidates.Add(Path.Combine(localAppData, "Microsoft", "WinGet", "Links", "ffmpeg" + exe));
        }
        foreach (var candidate in candidates)
        {
            if (!File.Exists(candidate))
            {
                continue;
            }
            var probe = Path.Combine(Path.GetDirectoryName(candidate)!, "ffprobe" + exe);
            if (File.Exists(probe))
            {
                return new Ffmpeg(candidate, probe);
            }
        }
        return null;
    }

    public static string F(double value) => value.ToString("0.######", CultureInfo.InvariantCulture);

    public Process Start(IEnumerable<string> args, bool redirectInput = false, bool redirectOutput = false, bool probe = false)
    {
        var info = new ProcessStartInfo(probe ? FfprobePath : FfmpegPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardInput = redirectInput,
            RedirectStandardOutput = redirectOutput,
        };
        foreach (var arg in args)
        {
            info.ArgumentList.Add(arg);
        }
        return Process.Start(info) ?? throw new FfmpegException("ffmpeg could not start");
    }

    /// <summary>Runs to completion; throws with the last stderr lines on failure.</summary>
    public async Task<string> RunAsync(IEnumerable<string> args, CancellationToken ct = default, bool probe = false)
    {
        using var process = Start(args, redirectOutput: true, probe: probe);
        var output = process.StandardOutput.ReadToEndAsync(ct);
        var error = process.StandardError.ReadToEndAsync(ct);
        try
        {
            await process.WaitForExitAsync(ct);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }
        var stdout = await output;
        var stderr = await error;
        if (process.ExitCode != 0)
        {
            throw new FfmpegException(Tail(stderr));
        }
        return probe ? stdout : stderr;
    }

    public async Task<MediaInfo> ProbeAsync(string file, CancellationToken ct = default)
    {
        var json = await RunAsync(new[]
        {
            "-v", "error", "-show_entries", "stream=codec_type,width,height:format=duration", "-of", "json", file,
        }, ct, probe: true);
        using var doc = JsonDocument.Parse(json);
        int width = 0, height = 0;
        bool video = false, audio = false;
        if (doc.RootElement.TryGetProperty("streams", out var streams))
        {
            foreach (var stream in streams.EnumerateArray())
            {
                var type = stream.GetProperty("codec_type").GetString();
                if (type == "video" && !video)
                {
                    video = true;
                    width = stream.TryGetProperty("width", out var w) ? w.GetInt32() : 0;
                    height = stream.TryGetProperty("height", out var h) ? h.GetInt32() : 0;
                }
                audio |= type == "audio";
            }
        }
        var duration = 0.0;
        if (doc.RootElement.TryGetProperty("format", out var format) && format.TryGetProperty("duration", out var d))
        {
            double.TryParse(d.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out duration);
        }
        return new MediaInfo(width, height, duration, video, audio);
    }

    /// <summary>DirectShow cameras and microphones (Windows).</summary>
    public async Task<CaptureDevices> ListDevicesAsync(CancellationToken ct = default)
    {
        using var process = Start(new[] { "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy" });
        var text = await process.StandardError.ReadToEndAsync(ct);
        await process.WaitForExitAsync(ct);
        return ParseDevices(text);
    }

    public static CaptureDevices ParseDevices(string text)
    {
        var video = new List<string>();
        var audio = new List<string>();
        List<string>? section = null;
        foreach (var line in text.Split('\n'))
        {
            if (line.Contains("Alternative name", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (line.Contains("DirectShow video devices", StringComparison.OrdinalIgnoreCase))
            {
                section = video;
                continue;
            }
            if (line.Contains("DirectShow audio devices", StringComparison.OrdinalIgnoreCase))
            {
                section = audio;
                continue;
            }
            var match = Regex.Match(line, "\"([^\"]+)\"\\s*(\\((video|audio|none)\\))?");
            if (!match.Success)
            {
                continue;
            }
            var name = match.Groups[1].Value;
            var kind = match.Groups[3].Value;
            var target = kind == "video" ? video : kind == "audio" ? audio : kind == "" ? section : null;
            if (target != null && !target.Contains(name))
            {
                target.Add(name);
            }
        }
        return new CaptureDevices(video, audio);
    }

    public static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    public static string Tail(string text, int lines = 6)
    {
        var all = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        return string.Join("\n", all.Skip(Math.Max(0, all.Length - lines))).Trim();
    }
}

/// <summary>Collects the last stderr lines of a running process (it must be drained to avoid blocking).</summary>
public sealed class StderrTail
{
    private readonly Queue<string> lines = new();
    private readonly object gate = new();

    public void Attach(Process process)
    {
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null)
            {
                return;
            }
            lock (gate)
            {
                lines.Enqueue(e.Data);
                while (lines.Count > 12)
                {
                    lines.Dequeue();
                }
            }
        };
        process.BeginErrorReadLine();
    }

    public override string ToString()
    {
        lock (gate)
        {
            var builder = new StringBuilder();
            foreach (var line in lines)
            {
                builder.AppendLine(line);
            }
            return builder.ToString().Trim();
        }
    }
}

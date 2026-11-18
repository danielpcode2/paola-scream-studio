using System.Text.Json;
using System.Text.Json.Serialization;

namespace PaolaScreenStudio.Core;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum CaptureMode { Display, Window, Area }

public sealed class Preferences
{
    public Language Language { get; set; } = Strings.SystemLanguage();
    public string ProjectsDirectory { get; set; } = DefaultProjectsDirectory;
    /// <summary>Empty = search next to the app, in PATH and in the WinGet links folder.</summary>
    public string FfmpegPath { get; set; } = "";
    public int Countdown { get; set; } = 3;
    public CaptureMode Mode { get; set; } = CaptureMode.Display;
    public string? Camera { get; set; }
    public string? Microphone { get; set; }
    public bool SystemAudio { get; set; } = true;
    public int BubbleSize { get; set; } = 200;
    public CameraShape BubbleShape { get; set; } = CameraShape.Circle;
    public Rgba BubbleBorder { get; set; } = Rgba.White;
    public ExportOptions Export { get; set; } = new();

    public static string DefaultProjectsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "Paola Screen Studio");

    public static Preferences Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path), ProjectStore.Json) ?? new Preferences();
            }
        }
        catch (JsonException)
        {
            // Corrupt settings: start from defaults.
        }
        return new Preferences();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, ProjectStore.Json));
    }
}

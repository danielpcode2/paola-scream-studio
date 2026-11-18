using System.IO;
using System.Windows;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

public partial class App : Application
{
    public static string SettingsPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Paola Screen Studio", "settings.json");

    public static Preferences Prefs { get; private set; } = new();

    /// <summary>Raised after the language changes so open windows refresh their texts.</summary>
    public static event Action? LanguageChanged;

    public static Ffmpeg? FindFfmpeg() => Ffmpeg.Locate(Prefs.FfmpegPath);

    public static void SavePrefs() => Prefs.Save(SettingsPath);

    public static void SetLanguage(Language language)
    {
        Prefs.Language = language;
        Strings.Current = language;
        SavePrefs();
        LanguageChanged?.Invoke();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        Prefs = Preferences.Load(SettingsPath);
        Strings.Current = Prefs.Language;
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(args.Exception.Message, "Paola Screen Studio", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
        base.OnStartup(e);

        var main = new MainWindow();
        MainWindow = main;
        main.Show();
        // "--open <folder>" opens a project directly in the editor.
        var index = Array.IndexOf(e.Args, "--open");
        if (index >= 0 && index + 1 < e.Args.Length)
        {
            main.OpenProject(e.Args[index + 1]);
        }
    }
}

using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

public partial class MainWindow : Window
{
    private static readonly string NoneItem = "—";
    private ScreenRect? selectedArea;
    private RecordingController? recording;

    public MainWindow()
    {
        InitializeComponent();
        LanguageBox.ItemsSource = new[] { "Español", "English" };
        LanguageBox.SelectedIndex = App.Prefs.Language == Core.Language.Spanish ? 0 : 1;
        CountdownBox.ItemsSource = new[] { 0, 3, 5, 10 };
        CountdownBox.SelectedItem = App.Prefs.Countdown;
        SystemAudioBox.IsChecked = App.Prefs.SystemAudio;
        DisplayBox.ItemsSource = ScreenInfo.Monitors();
        DisplayBox.SelectedIndex = 0;
        RefreshWindowList();
        switch (App.Prefs.Mode)
        {
            case CaptureMode.Window: ModeWindow.IsChecked = true; break;
            case CaptureMode.Area: ModeArea.IsChecked = true; break;
            default: ModeDisplay.IsChecked = true; break;
        }
        ApplyTexts();
        App.LanguageChanged += ApplyTexts;
        Loaded += async (_, _) =>
        {
            await LoadDevicesAsync();
            RefreshProjectList();
        };
        Closed += (_, _) => App.LanguageChanged -= ApplyTexts;
    }

    private void ApplyTexts()
    {
        Subtitle.Text = Strings.T("app.subtitle");
        SettingsButton.Content = Strings.T("settings.title");
        WhatLabel.Text = Strings.T("record.what").ToUpperInvariant();
        ModeDisplay.Content = Strings.T("mode.display");
        ModeWindow.Content = Strings.T("mode.window");
        ModeArea.Content = Strings.T("mode.area");
        SelectAreaButton.Content = Strings.T("area.select");
        AreaLabel.Text = selectedArea is ScreenRect a ? $"{a.Width} × {a.Height}" : Strings.T("area.none");
        CameraLabel.Text = Strings.T("record.camera").ToUpperInvariant();
        MicLabel.Text = Strings.T("record.microphone").ToUpperInvariant();
        SystemAudioBox.Content = Strings.T("record.system_audio");
        CountdownLabel.Text = Strings.T("record.countdown").ToUpperInvariant();
        RecordButton.Content = Strings.T("record.start");
        HotkeysHint.Text = Strings.T("record.hotkeys");
        ProjectsLabel.Text = Strings.T("projects.title").ToUpperInvariant();
        OpenFolderButton.Content = Strings.T("projects.folder");
        OpenProjectButton.Content = Strings.T("projects.open");
        ShowProjectButton.Content = Strings.T("projects.show");
        DeleteProjectButton.Content = Strings.T("projects.delete");
        UpdateFfmpegWarning();
    }

    private void UpdateFfmpegWarning()
    {
        var missing = App.FindFfmpeg() == null;
        FfmpegWarning.Text = Strings.T("ffmpeg.missing");
        FfmpegWarning.Visibility = missing ? Visibility.Visible : Visibility.Collapsed;
        RecordButton.IsEnabled = !missing && recording == null;
    }

    private async Task LoadDevicesAsync()
    {
        var cameras = new List<string> { NoneItem };
        var mics = new List<string> { NoneItem };
        if (App.FindFfmpeg() is Ffmpeg ffmpeg)
        {
            try
            {
                var devices = await ffmpeg.ListDevicesAsync();
                cameras.AddRange(devices.Video);
                mics.AddRange(devices.Audio);
            }
            catch (Exception ex) when (ex is FfmpegException or IOException)
            {
            }
        }
        CameraBox.ItemsSource = cameras;
        MicBox.ItemsSource = mics;
        CameraBox.SelectedItem = App.Prefs.Camera != null && cameras.Contains(App.Prefs.Camera) ? App.Prefs.Camera : NoneItem;
        MicBox.SelectedItem = App.Prefs.Microphone != null && mics.Contains(App.Prefs.Microphone) ? App.Prefs.Microphone : NoneItem;
    }

    private void RefreshWindowList()
    {
        WindowBox.ItemsSource = ScreenInfo.Windows();
        WindowBox.SelectedIndex = 0;
    }

    public void RefreshProjectList()
    {
        ProjectList.ItemsSource = ProjectStore.List(App.Prefs.ProjectsDirectory)
            .Select(folder => new ProjectItem(folder))
            .ToList();
    }

    private void Mode_Changed(object sender, RoutedEventArgs e)
    {
        DisplayBox.Visibility = ModeDisplay.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        WindowPanel.Visibility = ModeWindow.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        AreaPanel.Visibility = ModeArea.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshWindows_Click(object sender, RoutedEventArgs e) => RefreshWindowList();

    private void SelectArea_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        var area = RegionSelectorWindow.Select();
        Show();
        if (area is ScreenRect a && a.Width >= 64 && a.Height >= 64)
        {
            selectedArea = a.Even();
            AreaLabel.Text = $"{selectedArea.Value.Width} × {selectedArea.Value.Height}";
        }
    }

    private async void Record_Click(object sender, RoutedEventArgs e)
    {
        if (App.FindFfmpeg() is not Ffmpeg ffmpeg)
        {
            UpdateFfmpegWarning();
            return;
        }
        var request = BuildRequest();
        if (request == null)
        {
            return;
        }
        SaveChoices(request.Mode);
        recording = new RecordingController(ffmpeg, request, this);
        RecordButton.IsEnabled = false;
        try
        {
            await recording.RunAsync();
        }
        finally
        {
            recording = null;
            RecordButton.IsEnabled = true;
            RefreshProjectList();
        }
    }

    private RecordingRequest? BuildRequest()
    {
        var camera = CameraBox.SelectedItem as string;
        var mic = MicBox.SelectedItem as string;
        var common = new
        {
            Camera = camera == NoneItem ? null : camera,
            Mic = mic == NoneItem ? null : mic,
            System = SystemAudioBox.IsChecked == true,
        };
        if (ModeWindow.IsChecked == true)
        {
            if (WindowBox.SelectedItem is not WindowInfo window || ScreenInfo.WindowBounds(window.Handle) is not ScreenRect bounds)
            {
                MessageBox.Show(this, Strings.T("error.no_window"), Title);
                return null;
            }
            return new RecordingRequest
            {
                Mode = CaptureMode.Window, Area = bounds, WindowTitle = window.Title,
                Camera = common.Camera, Microphone = common.Mic, SystemAudio = common.System,
            };
        }
        if (ModeArea.IsChecked == true)
        {
            if (selectedArea is not ScreenRect area)
            {
                SelectArea_Click(this, new RoutedEventArgs());
                if (selectedArea is not ScreenRect chosen)
                {
                    return null;
                }
                area = chosen;
            }
            return new RecordingRequest
            {
                Mode = CaptureMode.Area, Area = area,
                Camera = common.Camera, Microphone = common.Mic, SystemAudio = common.System,
            };
        }
        var monitor = DisplayBox.SelectedItem as MonitorInfo ?? ScreenInfo.Monitors().First();
        return new RecordingRequest
        {
            Mode = CaptureMode.Display, Area = monitor.Bounds,
            Camera = common.Camera, Microphone = common.Mic, SystemAudio = common.System,
        };
    }

    private void SaveChoices(CaptureMode mode)
    {
        App.Prefs.Mode = mode;
        App.Prefs.Camera = CameraBox.SelectedItem as string == NoneItem ? null : CameraBox.SelectedItem as string;
        App.Prefs.Microphone = MicBox.SelectedItem as string == NoneItem ? null : MicBox.SelectedItem as string;
        App.Prefs.SystemAudio = SystemAudioBox.IsChecked == true;
        App.Prefs.Countdown = CountdownBox.SelectedItem is int c ? c : 3;
        App.SavePrefs();
    }

    private void LanguageChanged_(object sender, SelectionChangedEventArgs e)
    {
        if (!IsInitialized || LanguageBox.SelectedIndex < 0)
        {
            return;
        }
        var language = LanguageBox.SelectedIndex == 0 ? Core.Language.Spanish : Core.Language.English;
        if (language != Strings.Current)
        {
            App.SetLanguage(language);
        }
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var window = new SettingsWindow { Owner = this };
        if (window.ShowDialog() == true)
        {
            UpdateFfmpegWarning();
            _ = LoadDevicesAsync();
            RefreshProjectList();
        }
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(App.Prefs.ProjectsDirectory);
        Process.Start(new ProcessStartInfo("explorer.exe", App.Prefs.ProjectsDirectory) { UseShellExecute = true });
    }

    private void RefreshProjects_Click(object sender, RoutedEventArgs e) => RefreshProjectList();

    private void OpenProject_Click(object sender, RoutedEventArgs e)
    {
        if (ProjectList.SelectedItem is ProjectItem item)
        {
            OpenProject(item.Folder);
        }
    }

    public void OpenProject(string folder)
    {
        try
        {
            var editor = new EditorWindow(folder);
            editor.Closed += (_, _) => RefreshProjectList();
            editor.Show();
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException)
        {
            MessageBox.Show(this, ex.Message, Title, MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ShowProject_Click(object sender, RoutedEventArgs e)
    {
        if (ProjectList.SelectedItem is ProjectItem item)
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{item.Folder}\"") { UseShellExecute = true });
        }
    }

    private void DeleteProject_Click(object sender, RoutedEventArgs e)
    {
        if (ProjectList.SelectedItem is not ProjectItem item)
        {
            return;
        }
        var answer = MessageBox.Show(this, Strings.T("projects.delete_confirm", item.Name), Title,
            MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.Yes)
        {
            return;
        }
        try
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(item.Folder,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
        catch (IOException ex)
        {
            MessageBox.Show(this, ex.Message, Title);
        }
        RefreshProjectList();
    }

    private sealed class ProjectItem
    {
        public ProjectItem(string folder)
        {
            Folder = folder;
            Name = Path.GetFileName(folder);
        }

        public string Folder { get; }
        public string Name { get; }

        public override string ToString() => Name;
    }
}

using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

/// <summary>FFmpeg location and projects folder.</summary>
internal sealed class SettingsWindow : Window
{
    private readonly TextBox ffmpeg = new() { Margin = new Thickness(0, 0, 8, 0) };
    private readonly TextBox projects = new() { Margin = new Thickness(0, 0, 8, 0) };
    private readonly TextBlock status = new() { Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap };

    public SettingsWindow()
    {
        Title = Strings.T("settings.title");
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = (System.Windows.Media.Brush)Application.Current.Resources["Panel"];
        ffmpeg.Text = App.Prefs.FfmpegPath;
        projects.Text = App.Prefs.ProjectsDirectory;
        ffmpeg.TextChanged += (_, _) => UpdateStatus();

        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(new TextBlock { Text = Strings.T("settings.ffmpeg"), Style = (Style)Application.Current.Resources["Section"], Margin = new Thickness(0, 0, 0, 6) });
        panel.Children.Add(Row(ffmpeg, Strings.T("settings.browse"), BrowseFfmpeg));
        panel.Children.Add(status);
        panel.Children.Add(new TextBlock { Text = Strings.T("settings.ffmpeg_hint"), Foreground = (System.Windows.Media.Brush)Application.Current.Resources["Muted"], TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), FontSize = 11 });
        panel.Children.Add(new TextBlock { Text = Strings.T("settings.projects"), Style = (Style)Application.Current.Resources["Section"] });
        panel.Children.Add(Row(projects, Strings.T("settings.browse"), BrowseProjects));

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 20, 0, 0) };
        var cancel = new Button { Content = Strings.T("cancel"), IsCancel = true };
        var save = new Button { Content = Strings.T("save"), IsDefault = true, Margin = new Thickness(8, 0, 0, 0), Style = (Style)Application.Current.Resources["Primary"], Padding = new Thickness(16, 6, 16, 6) };
        save.Click += (_, _) => Save();
        buttons.Children.Add(cancel);
        buttons.Children.Add(save);
        panel.Children.Add(buttons);
        Content = panel;
        UpdateStatus();
    }

    private static DockPanel Row(TextBox box, string button, Action browse)
    {
        var row = new DockPanel();
        var b = new Button { Content = button };
        b.Click += (_, _) => browse();
        DockPanel.SetDock(b, Dock.Right);
        row.Children.Add(b);
        row.Children.Add(box);
        return row;
    }

    private void UpdateStatus()
    {
        var found = Ffmpeg.Locate(ffmpeg.Text);
        status.Text = found != null ? "✓ " + found.FfmpegPath : "✕ " + Strings.T("ffmpeg.missing");
        status.Foreground = found != null
            ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(120, 220, 150))
            : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 180, 180));
    }

    private void BrowseFfmpeg()
    {
        var dialog = new OpenFileDialog { Filter = "ffmpeg.exe|ffmpeg.exe", Title = Strings.T("settings.ffmpeg") };
        if (dialog.ShowDialog(this) == true)
        {
            ffmpeg.Text = dialog.FileName;
        }
    }

    private void BrowseProjects()
    {
#if NET8_0_OR_GREATER
        var dialog = new OpenFolderDialog { InitialDirectory = projects.Text };
        if (dialog.ShowDialog(this) == true)
        {
            projects.Text = dialog.FolderName;
        }
#else
        projects.Focus();
#endif
    }

    private void Save()
    {
        App.Prefs.FfmpegPath = ffmpeg.Text.Trim();
        var folder = projects.Text.Trim();
        App.Prefs.ProjectsDirectory = string.IsNullOrEmpty(folder) ? Preferences.DefaultProjectsDirectory : folder;
        try
        {
            Directory.CreateDirectory(App.Prefs.ProjectsDirectory);
        }
        catch (IOException ex)
        {
            MessageBox.Show(this, ex.Message, Title);
            return;
        }
        App.SavePrefs();
        DialogResult = true;
    }
}

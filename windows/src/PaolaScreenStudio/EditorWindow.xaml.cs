using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

/// <summary>
/// Editor: live preview (WPF composition using the same <see cref="Layout"/> math as the exporter),
/// inspector, timeline, undo/redo, autosave and export.
/// </summary>
public partial class EditorWindow : Window
{
    private readonly string folder;
    private readonly Project project;
    private readonly CursorPath cursorPath;
    private readonly int outW;
    private readonly int outH;
    private readonly Stack<string> undo = new();
    private readonly Stack<string> redo = new();
    private readonly DispatcherTimer saveTimer = new() { Interval = TimeSpan.FromMilliseconds(800) };
    private DateTime lastCheckpoint = DateTime.MinValue;
    private TimeMap map;
    private bool playing;
    private bool hasCamera;
    private double duration;
    private CancellationTokenSource? exportCancel;
    private ProgressBar? exportProgress;
    private Button? exportCancelButton;

    private EditSettings S => project.Settings;

    public EditorWindow(string folder)
    {
        InitializeComponent();
        this.folder = folder;
        project = ProjectStore.Load(folder);
        duration = Math.Max(0.1, project.Recording.Duration);
        cursorPath = new CursorPath(project.Recording.Cursor, project.Recording.Width, project.Recording.Height);
        (outW, outH) = Layout.OutputSize(Math.Max(2, project.Recording.Width), Math.Max(2, project.Recording.Height), 1080);
        map = new TimeMap(duration, S);

        Stage.Width = outW;
        Stage.Height = outH;
        ScreenPlayer.MediaOpened += (_, _) =>
        {
            if (ScreenPlayer.NaturalDuration.HasTimeSpan)
            {
                duration = ScreenPlayer.NaturalDuration.TimeSpan.TotalSeconds;
                Timeline.Duration = duration;
                map = new TimeMap(duration, S);
            }
            // Show the first frame.
            ScreenPlayer.Play();
            ScreenPlayer.Pause();
            Seek(map.Kept.Count > 0 ? map.Kept[0].Start : 0);
        };
        ScreenPlayer.MediaFailed += (_, e) => MessageBox.Show(this, e.ErrorException.Message, Title, MessageBoxButton.OK, MessageBoxImage.Error);
        ScreenPlayer.Source = new Uri(Path.Combine(folder, project.Recording.ScreenFile));
        var cameraPath = project.Recording.CameraFile is string c ? Path.Combine(folder, c) : null;
        hasCamera = cameraPath != null && File.Exists(cameraPath);
        if (hasCamera)
        {
            CameraPlayer.Source = new Uri(cameraPath!);
            CameraPlayer.MediaOpened += (_, _) =>
            {
                CameraPlayer.Play();
                CameraPlayer.Pause();
            };
        }

        Timeline.Settings = S;
        Timeline.Duration = duration;
        Timeline.WillChange += Checkpoint;
        Timeline.Changed += OnChanged;
        Timeline.SeekRequested += Seek;
        Timeline.SelectionChanged += _ => BuildInspector();

        saveTimer.Tick += (_, _) => Save();
        CompositionTarget.Rendering += OnFrame;
        Closing += (_, _) => Shutdown();
        PreviewKeyDown += OnKey;
        App.LanguageChanged += OnLanguage;

        ApplyTexts();
        ApplyLayout();
        BuildInspector();
    }

    private void OnLanguage()
    {
        ApplyTexts();
        BuildInspector();
        Timeline.InvalidateVisual();
    }

    private void ApplyTexts()
    {
        Title = $"{project.Name} — Paola Screen Studio";
        TitleText.Text = project.Name;
        ExportButton.Content = Strings.T("export.button");
        AddZoomButton.Content = "🔍 " + Strings.T("timeline.add_zoom");
        AddCutButton.Content = "✂ " + Strings.T("timeline.add_cut");
        TrimStartButton.Content = "⇤ " + Strings.T("timeline.trim_start");
        TrimEndButton.Content = Strings.T("timeline.trim_end") + " ⇥";
        UndoButton.ToolTip = Strings.T("edit.undo") + " (Ctrl+Z)";
        RedoButton.ToolTip = Strings.T("edit.redo") + " (Ctrl+Y)";
        AddZoomButton.ToolTip = "Z";
        AddCutButton.ToolTip = "C";
    }

    // MARK: Preview

    private void ApplyLayout()
    {
        BackgroundRect.Width = outW;
        BackgroundRect.Height = outH;
        BackgroundRect.Fill = S.Background switch
        {
            BackgroundKind.Gradient => new LinearGradientBrush(ToColor(S.Gradient.Start), ToColor(S.Gradient.End), new Point(0, 0), new Point(1, 1)),
            BackgroundKind.Color => new SolidColorBrush(ToColor(S.BackgroundColor)),
            _ => Brushes.Black,
        };

        var content = Layout.Content(outW, outH, Math.Max(2, project.Recording.Width), Math.Max(2, project.Recording.Height), S);
        var radius = Layout.CornerRadius(outW, outH, S);
        Place(ContentBox, content);
        Place(ShadowBox, content);
        ContentBox.CornerRadius = new CornerRadius(radius);
        ContentBox.Clip = new RectangleGeometry(new Rect(0, 0, content.W, content.H), radius, radius);
        ShadowBox.CornerRadius = new CornerRadius(radius);
        ShadowBox.Visibility = S.Background != BackgroundKind.None && S.Shadow > 0 ? Visibility.Visible : Visibility.Collapsed;
        Shadow.Opacity = Math.Clamp(S.Shadow, 0, 1) * 0.8;
        Shadow.BlurRadius = Math.Min(outW, outH) * 0.04;
        ZoomCanvas.Width = content.W;
        ZoomCanvas.Height = content.H;
        ScreenPlayer.Width = content.W;
        ScreenPlayer.Height = content.H;

        CameraBox.Visibility = hasCamera && S.ShowCamera ? Visibility.Visible : Visibility.Collapsed;
        var camera = Layout.Camera(outW, outH, S);
        Place(CameraBox, camera);
        var half = camera.W / 2;
        var r = Layout.ShapeRadius(S.CameraShape, half);
        CameraClip.CornerRadius = new CornerRadius(r);
        CameraClip.Clip = new RectangleGeometry(new Rect(0, 0, camera.W, camera.H), r, r);
        var border = Layout.BorderWidth(half);
        CameraRing.Margin = new Thickness(-border);
        CameraRing.CornerRadius = new CornerRadius(r + border);
        CameraRing.BorderThickness = new Thickness(S.CameraBorderColor.A == 0 ? 0 : border);
        CameraRing.BorderBrush = new SolidColorBrush(ToColor(S.CameraBorderColor));
        CameraPlayer.RenderTransform = new ScaleTransform(S.MirrorCamera ? -1 : 1, 1);
        UpdateZoom(ScreenPlayer.Position.TotalSeconds);
    }

    private static void Place(FrameworkElement element, Box box)
    {
        Canvas.SetLeft(element, box.X);
        Canvas.SetTop(element, box.Y);
        element.Width = box.W;
        element.Height = box.H;
    }

    private void UpdateZoom(double t)
    {
        var zoom = ZoomPlanner.At(t, S.Zooms, cursorPath);
        var (zx, zy, zw, _) = zoom.SourceRect;
        var scale = 1 / zw;
        var w = ScreenPlayer.Width;
        var h = ScreenPlayer.Height;
        ScreenPlayer.RenderTransform = new MatrixTransform(scale, 0, 0, scale, -zx * w * scale, -zy * h * scale);
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var t = ScreenPlayer.Position.TotalSeconds;
        if (playing && !map.IsKept(t))
        {
            if (map.NextKept(t) is double next)
            {
                Seek(next);
                t = next;
            }
            else
            {
                SetPlaying(false);
            }
        }
        UpdateZoom(t);
        if (hasCamera && playing)
        {
            var wanted = t - project.Recording.CameraOffset;
            if (Math.Abs(CameraPlayer.Position.TotalSeconds - wanted) > 0.25)
            {
                CameraPlayer.Position = TimeSpan.FromSeconds(Math.Max(0, wanted));
            }
        }
        if (Math.Abs(Timeline.Playhead - t) > 0.001)
        {
            Timeline.Playhead = t;
            Timeline.InvalidateVisual();
        }
        TimeText.Text = $"{TimelineControl.FormatTime(map.ToOutput(t))} / {TimelineControl.FormatTime(map.OutputDuration)}";
    }

    private void Seek(double t)
    {
        t = Math.Clamp(t, 0, duration);
        ScreenPlayer.Position = TimeSpan.FromSeconds(t);
        if (hasCamera)
        {
            CameraPlayer.Position = TimeSpan.FromSeconds(Math.Max(0, t - project.Recording.CameraOffset));
        }
        Timeline.Playhead = t;
        Timeline.InvalidateVisual();
        UpdateZoom(t);
    }

    private void SetPlaying(bool value)
    {
        playing = value;
        if (value)
        {
            var t = ScreenPlayer.Position.TotalSeconds;
            // Restart from the beginning when at the end.
            if (map.NextKept(t) is not double next || (map.Kept.Count > 0 && t >= map.Kept[^1].End - 0.05))
            {
                next = map.Kept.Count > 0 ? map.Kept[0].Start : 0;
            }
            Seek(next);
            ScreenPlayer.Play();
            if (hasCamera)
            {
                CameraPlayer.Play();
            }
        }
        else
        {
            ScreenPlayer.Pause();
            if (hasCamera)
            {
                CameraPlayer.Pause();
            }
        }
        PlayButton.Content = value ? "❚❚" : "▶";
    }

    private void Play_Click(object sender, RoutedEventArgs e) => SetPlaying(!playing);

    // MARK: Editing, undo, save

    private void Checkpoint()
    {
        var now = DateTime.UtcNow;
        if ((now - lastCheckpoint).TotalSeconds < 0.6)
        {
            lastCheckpoint = now;
            return;
        }
        lastCheckpoint = now;
        undo.Push(JsonSerializer.Serialize(S, ProjectStore.Json));
        redo.Clear();
    }

    private void OnChanged()
    {
        map = new TimeMap(duration, S);
        ApplyLayout();
        SavedText.Text = "";
        saveTimer.Stop();
        saveTimer.Start();
    }

    private void Edit(Action change)
    {
        Checkpoint();
        change();
        OnChanged();
        Timeline.InvalidateVisual();
    }

    private void Restore(Stack<string> from, Stack<string> to)
    {
        if (from.Count == 0)
        {
            return;
        }
        to.Push(JsonSerializer.Serialize(S, ProjectStore.Json));
        project.Settings = JsonSerializer.Deserialize<EditSettings>(from.Pop(), ProjectStore.Json) ?? new EditSettings();
        lastCheckpoint = DateTime.MinValue;
        Timeline.Settings = S;
        Timeline.Select(null);
        OnChanged();
        BuildInspector();
    }

    private void Undo_Click(object sender, RoutedEventArgs e) => Restore(undo, redo);

    private void Redo_Click(object sender, RoutedEventArgs e) => Restore(redo, undo);

    private void Save()
    {
        saveTimer.Stop();
        try
        {
            ProjectStore.Save(folder, project);
            SavedText.Text = "✓ " + Strings.T("editor.saved");
        }
        catch (IOException ex)
        {
            SavedText.Text = ex.Message;
        }
    }

    private void Shutdown()
    {
        if (saveTimer.IsEnabled)
        {
            Save();
        }
        exportCancel?.Cancel();
        CompositionTarget.Rendering -= OnFrame;
        App.LanguageChanged -= OnLanguage;
        ScreenPlayer.Close();
        CameraPlayer.Close();
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox)
        {
            return;
        }
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        switch (e.Key)
        {
            case Key.Space:
                SetPlaying(!playing);
                break;
            case Key.Delete or Key.Back:
                Timeline.DeleteSelected();
                break;
            case Key.Z when ctrl && shift:
            case Key.Y when ctrl:
                Restore(redo, undo);
                break;
            case Key.Z when ctrl:
                Restore(undo, redo);
                break;
            case Key.D when ctrl && Timeline.Selected != null:
                Timeline.Duplicate(Timeline.Selected);
                break;
            case Key.S when ctrl:
                Save();
                break;
            case Key.E when ctrl:
                Export_Click(this, new RoutedEventArgs());
                break;
            case Key.Z:
                Timeline.AddZoom(Timeline.Playhead);
                break;
            case Key.C:
                Timeline.AddCut(Timeline.Playhead);
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private void AddZoom_Click(object sender, RoutedEventArgs e) => Timeline.AddZoom(Timeline.Playhead);

    private void AddCut_Click(object sender, RoutedEventArgs e) => Timeline.AddCut(Timeline.Playhead);

    private void TrimStart_Click(object sender, RoutedEventArgs e) =>
        Edit(() => S.TrimStart = Math.Min(Timeline.Playhead, (S.TrimEnd ?? duration) - 0.5));

    private void TrimEnd_Click(object sender, RoutedEventArgs e) =>
        Edit(() => S.TrimEnd = Math.Max(Timeline.Playhead, S.TrimStart + 0.5));

    // MARK: Inspector

    private void BuildInspector()
    {
        Inspector.Children.Clear();
        switch (Timeline.Selected)
        {
            case ZoomSegment zoom:
                Section(Strings.T("inspector.selected_zoom"));
                Slider(Strings.T("zoom.level_label"), 1.1, 4, () => zoom.Scale, v => zoom.Scale = v, v => v.ToString("0.0", CultureInfo.CurrentCulture) + "×");
                var follow = Check(Strings.T("zoom.follow"), zoom.FocusX == null, v =>
                {
                    zoom.FocusX = v ? null : 0.5;
                    zoom.FocusY = v ? null : 0.5;
                    BuildInspector();
                });
                if (zoom.FocusX != null)
                {
                    Slider(Strings.T("zoom.focus_x"), 0, 1, () => zoom.FocusX ?? 0.5, v => zoom.FocusX = v, Percent);
                    Slider(Strings.T("zoom.focus_y"), 0, 1, () => zoom.FocusY ?? 0.5, v => zoom.FocusY = v, Percent);
                }
                ActionButton("🗑 " + Strings.T("item.delete"), () => Timeline.DeleteSelected());
                break;
            case CutSegment cut:
                Section(Strings.T("inspector.selected_cut"));
                Note(Strings.T("cut.hint", TimelineControl.FormatTime(cut.End - cut.Start)));
                ActionButton("🗑 " + Strings.T("item.delete"), () => Timeline.DeleteSelected());
                break;
        }

        Section(Strings.T("inspector.background"));
        Combo(new[] { Strings.T("background.gradient"), Strings.T("background.color"), Strings.T("background.none") },
            (int)S.Background, i => { S.Background = (BackgroundKind)i; BuildInspector(); });
        if (S.Background == BackgroundKind.Gradient)
        {
            var swatches = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            for (var i = 0; i < GradientPreset.All.Count; i++)
            {
                var index = i;
                var preset = GradientPreset.All[i];
                var swatch = Swatch(new LinearGradientBrush(ToColor(preset.Start), ToColor(preset.End), 45), S.GradientIndex == i, preset.Name);
                swatch.MouseLeftButtonDown += (_, _) => Edit(() => { S.GradientIndex = index; BuildInspector(); });
                swatches.Children.Add(swatch);
            }
            Inspector.Children.Add(swatches);
        }
        else if (S.Background == BackgroundKind.Color)
        {
            ColorRow(S.BackgroundColor, c => S.BackgroundColor = c, allowNone: false);
        }
        if (S.Background != BackgroundKind.None)
        {
            Slider(Strings.T("inspector.padding"), 0, 0.2, () => S.Padding, v => S.Padding = v, Percent);
            Slider(Strings.T("inspector.corners"), 0, 0.06, () => S.CornerRadius, v => S.CornerRadius = v, v => (v * 1000).ToString("0"));
            Slider(Strings.T("inspector.shadow"), 0, 1, () => S.Shadow, v => S.Shadow = v, Percent);
        }

        if (hasCamera)
        {
            Section(Strings.T("record.camera"));
            Check(Strings.T("camera.show"), S.ShowCamera, v => S.ShowCamera = v);
            Slider(Strings.T("inspector.size"), 0.1, 0.5, () => S.CameraSize, v => S.CameraSize = v, Percent);
            Label(Strings.T("camera.shape"));
            Combo(Enum.GetValues<CameraShape>().Select(s => Strings.T("camera.shape." + s.ToString().ToLowerInvariant())).ToArray(),
                (int)S.CameraShape, i => S.CameraShape = (CameraShape)i);
            Label(Strings.T("camera.corner"));
            Combo(new[] { "↘", "↙", "↗", "↖" }, (int)S.CameraCorner, i => S.CameraCorner = (CameraCorner)i);
            Label(Strings.T("camera.border_color"));
            ColorRow(S.CameraBorderColor, c => S.CameraBorderColor = c, allowNone: true);
            Check(Strings.T("camera.mirror"), S.MirrorCamera, v => S.MirrorCamera = v);
        }

        Section(Strings.T("inspector.zoom"));
        Slider(Strings.T("zoom.auto_level"), 1.2, 3, () => S.AutoZoomScale, v => S.AutoZoomScale = v, v => v.ToString("0.0", CultureInfo.CurrentCulture) + "×");
        ActionButton(Strings.T("zoom.regenerate", project.Recording.Clicks.Count), () =>
            Edit(() => S.Zooms = ZoomPlanner.Auto(project.Recording.Clicks, duration, S.AutoZoomScale)));
        Check(Strings.T("inspector.clicks"), S.ShowClicks, v => S.ShowClicks = v);
        Note(Strings.T("inspector.clicks_hint"));

        Section(Strings.T("export.title"));
        var export = App.Prefs.Export;
        Label(Strings.T("export.resolution"));
        var heights = new[] { 720, 1080, 1440, 2160 };
        Combo(new[] { "720p", "1080p", "1440p", "4K" }, Math.Max(0, Array.IndexOf(heights, export.Height)), i => { export.Height = heights[i]; App.SavePrefs(); }, undoable: false);
        Label("FPS");
        var rates = new[] { 24, 30, 60 };
        Combo(new[] { "24", "30", "60" }, Math.Max(0, Array.IndexOf(rates, export.Fps)), i => { export.Fps = rates[i]; App.SavePrefs(); }, undoable: false);
        Label(Strings.T("export.format"));
        Combo(new[] { "MP4", "GIF" }, (int)export.Format, i => { export.Format = (ExportFormat)i; App.SavePrefs(); }, undoable: false);
        Label(Strings.T("export.quality"));
        Combo(new[] { Strings.T("export.quality.high"), Strings.T("export.quality.medium"), Strings.T("export.quality.low") },
            (int)export.Quality, i => { export.Quality = (ExportQuality)i; App.SavePrefs(); }, undoable: false);
        exportProgress = new ProgressBar { Height = 6, Margin = new Thickness(0, 12, 0, 0), Visibility = exportCancel != null ? Visibility.Visible : Visibility.Collapsed, Maximum = 1 };
        Inspector.Children.Add(exportProgress);
        exportCancelButton = new Button { Content = Strings.T("cancel"), Margin = new Thickness(0, 8, 0, 0), Visibility = exportProgress.Visibility };
        exportCancelButton.Click += (_, _) => exportCancel?.Cancel();
        Inspector.Children.Add(exportCancelButton);
        Note(Strings.T("editor.shortcuts"));
    }

    private static string Percent(double v) => (v * 100).ToString("0", CultureInfo.CurrentCulture) + " %";

    private void Section(string text) =>
        Inspector.Children.Add(new TextBlock { Text = text.ToUpperInvariant(), Style = (Style)FindResource("Section") });

    private void Label(string text) =>
        Inspector.Children.Add(new TextBlock { Text = text, Margin = new Thickness(0, 8, 0, 4) });

    private void Note(string text) =>
        Inspector.Children.Add(new TextBlock { Text = text, Foreground = (Brush)FindResource("Muted"), TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(0, 6, 0, 0) });

    private void ActionButton(string text, Action action)
    {
        var button = new Button { Content = text, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        button.Click += (_, _) => action();
        Inspector.Children.Add(button);
    }

    private CheckBox Check(string text, bool value, Action<bool> set)
    {
        var box = new CheckBox { Content = text, IsChecked = value };
        box.Click += (_, _) => Edit(() => set(box.IsChecked == true));
        Inspector.Children.Add(box);
        return box;
    }

    private void Combo(string[] items, int selected, Action<int> set, bool undoable = true)
    {
        var box = new ComboBox { ItemsSource = items, SelectedIndex = selected };
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex < 0)
            {
                return;
            }
            if (undoable)
            {
                Edit(() => set(box.SelectedIndex));
            }
            else
            {
                set(box.SelectedIndex);
            }
        };
        Inspector.Children.Add(box);
    }

    private void Slider(string label, double min, double max, Func<double> get, Action<double> set, Func<double, string> format)
    {
        var value = new TextBlock { Foreground = (Brush)FindResource("Muted"), Text = format(get()) };
        var header = new DockPanel { Margin = new Thickness(0, 8, 0, 2) };
        DockPanel.SetDock(value, Dock.Right);
        header.Children.Add(value);
        header.Children.Add(new TextBlock { Text = label });
        var slider = new Slider { Minimum = min, Maximum = max, Value = get() };
        slider.ValueChanged += (_, e) =>
        {
            Edit(() => set(e.NewValue));
            value.Text = format(e.NewValue);
        };
        Inspector.Children.Add(header);
        Inspector.Children.Add(slider);
    }

    private static Border Swatch(Brush fill, bool selected, string tip) => new()
    {
        Width = 28,
        Height = 28,
        Margin = new Thickness(0, 0, 6, 6),
        CornerRadius = new CornerRadius(7),
        Background = fill,
        BorderBrush = selected ? Brushes.White : new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)),
        BorderThickness = new Thickness(selected ? 2 : 1),
        Cursor = Cursors.Hand,
        ToolTip = tip,
    };

    private static readonly (string Key, Rgba Color)[] ColorPresets =
    {
        ("white", Rgba.White),
        ("black", new Rgba(0, 0, 0, 230)),
        ("purple", new Rgba(139, 92, 246)),
        ("blue", new Rgba(51, 128, 255)),
        ("green", new Rgba(51, 199, 115)),
        ("orange", new Rgba(255, 140, 38)),
        ("pink", new Rgba(250, 89, 153)),
        ("none", Rgba.Transparent),
    };

    private void ColorRow(Rgba current, Action<Rgba> set, bool allowNone)
    {
        var row = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var (key, color) in ColorPresets)
        {
            if (color.A == 0 && !allowNone)
            {
                continue;
            }
            var value = color;
            var swatch = Swatch(color.A == 0 ? Brushes.Transparent : new SolidColorBrush(ToColor(color)), current == color, Strings.T("camera.border." + key));
            swatch.CornerRadius = new CornerRadius(14);
            if (color.A == 0)
            {
                swatch.Child = new TextBlock { Text = "⦸", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = (Brush)FindResource("Muted") };
            }
            swatch.MouseLeftButtonDown += (_, _) => Edit(() => { set(value); BuildInspector(); });
            row.Children.Add(swatch);
        }
        var hex = new TextBox { Text = current.A == 0 ? "" : current.Hex, Width = 80, VerticalContentAlignment = VerticalAlignment.Center, ToolTip = Strings.T("color.hex") };
        hex.LostFocus += (_, _) =>
        {
            if (Rgba.FromHex(hex.Text) is Rgba parsed && parsed != current)
            {
                Edit(() => set(parsed));
                BuildInspector();
            }
        };
        hex.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Keyboard.ClearFocus();
                Focus();
            }
        };
        row.Children.Add(hex);
        Inspector.Children.Add(row);
    }

    // MARK: Export

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (exportCancel != null)
        {
            return;
        }
        if (App.FindFfmpeg() is not Ffmpeg ffmpeg)
        {
            MessageBox.Show(this, Strings.T("ffmpeg.missing"), Title, MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        Save();
        var options = App.Prefs.Export;
        var gif = options.Format == ExportFormat.Gif;
        var dialog = new SaveFileDialog
        {
            FileName = project.Name + (gif ? ".gif" : ".mp4"),
            Filter = gif ? "GIF|*.gif" : "MP4|*.mp4",
            InitialDirectory = Path.Combine(App.Prefs.ProjectsDirectory, "Exports"),
        };
        Directory.CreateDirectory(dialog.InitialDirectory);
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }
        SetPlaying(false);
        exportCancel = new CancellationTokenSource();
        ExportButton.IsEnabled = false;
        BuildInspector();
        var progress = new Progress<double>(v =>
        {
            if (exportProgress != null)
            {
                exportProgress.Value = v;
            }
            ExportButton.Content = $"{v * 100:0} %";
        });
        try
        {
            var snapshot = JsonSerializer.Deserialize<Project>(JsonSerializer.Serialize(project, ProjectStore.Json), ProjectStore.Json)!;
            await Task.Run(() => Exporter.ExportAsync(ffmpeg, folder, snapshot, options, dialog.FileName, progress, exportCancel.Token));
            if (MessageBox.Show(this, Strings.T("export.done"), Title, MessageBoxButton.YesNo, MessageBoxImage.Information) == MessageBoxResult.Yes)
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{dialog.FileName}\"") { UseShellExecute = true });
            }
        }
        catch (OperationCanceledException)
        {
            TryDelete(dialog.FileName);
        }
        catch (Exception ex) when (ex is FfmpegException or IOException or InvalidOperationException)
        {
            TryDelete(dialog.FileName);
            MessageBox.Show(this, Strings.T("export.failed") + "\n\n" + ex.Message, Title, MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            exportCancel.Dispose();
            exportCancel = null;
            ExportButton.IsEnabled = true;
            ApplyTexts();
            BuildInspector();
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
        }
    }

    private static Color ToColor(Rgba c) => Color.FromArgb(c.A, c.R, c.G, c.B);
}

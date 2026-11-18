using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

/// <summary>Base for windows that must never appear in the recording.</summary>
public class HiddenFromCaptureWindow : Window
{
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        Native.ExcludeFromCapture(new WindowInteropHelper(this).Handle);
    }
}

/// <summary>Floating bar while recording: time, pause/resume, finish, cancel.</summary>
internal sealed class ControlBarWindow : HiddenFromCaptureWindow
{
    private readonly RecordingSession session;
    private readonly TextBlock time = new() { FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Width = 64 };
    private readonly Ellipse dot = new() { Width = 10, Height = 10, Fill = new SolidColorBrush(Color.FromRgb(255, 69, 107)), Margin = new Thickness(0, 0, 8, 0) };
    private readonly Button pause = new() { Margin = new Thickness(8, 0, 0, 0) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };

    public event Action? PauseRequested;
    public event Action? StopRequested;
    public event Action? CancelRequested;

    public ControlBarWindow(RecordingSession session)
    {
        this.session = session;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;

        var stop = new Button { Content = "■ " + Strings.T("record.finish"), Margin = new Thickness(8, 0, 0, 0), Style = (Style)Application.Current.Resources["Primary"], Padding = new Thickness(12, 6, 12, 6) };
        var cancel = new Button { Content = "✕", Margin = new Thickness(8, 0, 0, 0), ToolTip = Strings.T("record.cancel") };
        pause.Click += (_, _) => PauseRequested?.Invoke();
        stop.Click += (_, _) => StopRequested?.Invoke();
        cancel.Click += (_, _) =>
        {
            if (MessageBox.Show(Strings.T("record.cancel_confirm"), "Paola Screen Studio", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
            {
                CancelRequested?.Invoke();
            }
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(dot);
        row.Children.Add(time);
        row.Children.Add(pause);
        row.Children.Add(stop);
        row.Children.Add(cancel);
        Content = new Border
        {
            Background = (Brush)Application.Current.Resources["Panel"],
            BorderBrush = (Brush)Application.Current.Resources["Stroke"],
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 8, 8, 8),
            Child = row,
            ToolTip = Strings.T("record.hotkeys"),
        };
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is not Button)
            {
                DragMove();
            }
        };
        timer.Tick += (_, _) => Refresh();
        Loaded += (_, _) =>
        {
            var area = SystemParameters.WorkArea;
            Left = area.Left + (area.Width - ActualWidth) / 2;
            Top = area.Bottom - ActualHeight - 24;
            timer.Start();
            Refresh();
        };
        Closed += (_, _) => timer.Stop();
    }

    public void Refresh()
    {
        var elapsed = session.Elapsed;
        time.Text = $"{(int)elapsed.TotalMinutes:00}:{elapsed.Seconds:00}";
        pause.Content = session.IsPaused ? "▶ " + Strings.T("record.resume") : "❚❚ " + Strings.T("record.pause");
        dot.Opacity = session.IsPaused ? 0.3 : (DateTime.Now.Millisecond < 500 ? 1 : 0.45);
    }
}

/// <summary>Big countdown in the middle of the screen. Esc cancels.</summary>
internal sealed class CountdownWindow : HiddenFromCaptureWindow
{
    private readonly TextBlock number = new() { FontSize = 96, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private bool cancelled;

    private CountdownWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        Width = 200;
        Height = 200;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(220, 20, 20, 26)),
            CornerRadius = new CornerRadius(100),
            Child = number,
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                cancelled = true;
            }
        };
    }

    public static async Task<bool> RunAsync(int seconds)
    {
        var window = new CountdownWindow();
        window.Show();
        window.Activate();
        for (var i = seconds; i > 0 && !window.cancelled; i--)
        {
            window.number.Text = i.ToString();
            await Task.Delay(1000);
        }
        window.Close();
        // Give the window time to disappear before capture starts.
        await Task.Delay(150);
        return !window.cancelled;
    }
}

/// <summary>Small "please wait" window.</summary>
internal sealed class BusyWindow : Window
{
    public BusyWindow(string message)
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)Application.Current.Resources["Panel"];
        var panel = new StackPanel { Margin = new Thickness(28, 22, 28, 22), Width = 280 };
        panel.Children.Add(new TextBlock { Text = message, Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 6 });
        Content = panel;
    }
}

/// <summary>Drag a rectangle over the whole desktop; returns physical pixels or null (Esc).</summary>
internal sealed class RegionSelectorWindow : Window
{
    private readonly Canvas canvas = new() { Background = new SolidColorBrush(Color.FromArgb(70, 0, 0, 0)) };
    private readonly Rectangle box = new() { Stroke = new SolidColorBrush(Color.FromRgb(139, 92, 246)), StrokeThickness = 2, Fill = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255)), Visibility = Visibility.Collapsed };
    private readonly TextBlock size = new() { Foreground = Brushes.White, FontWeight = FontWeights.SemiBold, Visibility = Visibility.Collapsed };
    private Point start;
    private Native.POINT startPixel;
    private ScreenRect? result;

    private RegionSelectorWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        Cursor = Cursors.Cross;
        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;
        canvas.Children.Add(box);
        canvas.Children.Add(size);
        var hint = new TextBlock
        {
            Text = Strings.T("area.hint"),
            Foreground = Brushes.White,
            FontSize = 16,
            Margin = new Thickness(24),
        };
        canvas.Children.Add(hint);
        Content = canvas;
        MouseLeftButtonDown += (_, e) =>
        {
            start = e.GetPosition(canvas);
            Native.GetCursorPos(out startPixel);
            box.Visibility = Visibility.Visible;
            size.Visibility = Visibility.Visible;
            CaptureMouse();
            Update(start);
        };
        MouseMove += (_, e) =>
        {
            if (IsMouseCaptured)
            {
                Update(e.GetPosition(canvas));
            }
        };
        MouseLeftButtonUp += (_, _) =>
        {
            ReleaseMouseCapture();
            Native.GetCursorPos(out var end);
            var x = Math.Min(startPixel.X, end.X);
            var y = Math.Min(startPixel.Y, end.Y);
            result = new ScreenRect(x, y, Math.Abs(end.X - startPixel.X), Math.Abs(end.Y - startPixel.Y));
            Close();
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
    }

    private void Update(Point current)
    {
        var x = Math.Min(start.X, current.X);
        var y = Math.Min(start.Y, current.Y);
        Canvas.SetLeft(box, x);
        Canvas.SetTop(box, y);
        box.Width = Math.Abs(current.X - start.X);
        box.Height = Math.Abs(current.Y - start.Y);
        Native.GetCursorPos(out var now);
        size.Text = $"{Math.Abs(now.X - startPixel.X)} × {Math.Abs(now.Y - startPixel.Y)}";
        Canvas.SetLeft(size, x + 6);
        Canvas.SetTop(size, Math.Max(0, y - 24));
    }

    public static ScreenRect? Select()
    {
        var window = new RegionSelectorWindow();
        window.ShowDialog();
        return window.result;
    }
}

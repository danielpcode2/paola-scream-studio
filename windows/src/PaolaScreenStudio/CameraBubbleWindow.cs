using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

/// <summary>Live camera bubble while recording. Drag to move; right-click for size, shape and border color.</summary>
internal sealed class CameraBubbleWindow : HiddenFromCaptureWindow
{
    private static readonly (string Key, Rgba Color)[] BorderPresets =
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

    private static readonly int[] Sizes = { 140, 200, 280, 380 };

    private readonly Image image = new() { Stretch = Stretch.UniformToFill };
    private readonly Border frame = new();
    private readonly Border ring = new() { IsHitTestVisible = false };

    public CameraBubbleWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        image.RenderTransformOrigin = new Point(0.5, 0.5);
        image.RenderTransform = new ScaleTransform(-1, 1); // mirror, like looking in a mirror
        frame.Background = new SolidColorBrush(Color.FromRgb(24, 24, 28));
        frame.Child = image;
        var grid = new Grid();
        grid.Children.Add(frame);
        grid.Children.Add(ring);
        Content = grid;
        ToolTip = Strings.T("bubble.hint");
        MouseLeftButtonDown += (_, _) => DragMove();
        ContextMenu = BuildMenu();
        ApplyLook();
        Loaded += (_, _) =>
        {
            var area = SystemParameters.WorkArea;
            Left = area.Right - Width - 32;
            Top = area.Bottom - Height - 96;
        };
    }

    public void ShowFrame(BitmapSource? bitmap)
    {
        if (bitmap != null)
        {
            image.Source = bitmap;
        }
    }

    private ContextMenu BuildMenu()
    {
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = Strings.T("bubble.size"), IsEnabled = false });
        string[] sizeKeys = { "small", "medium", "large", "xlarge" };
        for (var i = 0; i < Sizes.Length; i++)
        {
            var value = Sizes[i];
            var item = new MenuItem { Header = Strings.T("bubble.size." + sizeKeys[i]), IsCheckable = true, IsChecked = App.Prefs.BubbleSize == value };
            item.Click += (_, _) => { App.Prefs.BubbleSize = value; Changed(); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = Strings.T("camera.shape"), IsEnabled = false });
        foreach (var shape in Enum.GetValues<CameraShape>())
        {
            var value = shape;
            var item = new MenuItem { Header = Strings.T("camera.shape." + shape.ToString().ToLowerInvariant()), IsCheckable = true, IsChecked = App.Prefs.BubbleShape == value };
            item.Click += (_, _) => { App.Prefs.BubbleShape = value; Changed(); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = Strings.T("camera.border_color"), IsEnabled = false });
        foreach (var (key, color) in BorderPresets)
        {
            var value = color;
            var item = new MenuItem
            {
                Header = Strings.T("camera.border." + key),
                IsCheckable = true,
                IsChecked = App.Prefs.BubbleBorder == value,
                Icon = new Border
                {
                    Width = 12, Height = 12, CornerRadius = new CornerRadius(6),
                    Background = value.A == 0 ? Brushes.Transparent : new SolidColorBrush(ToColor(value)),
                    BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1),
                },
            };
            item.Click += (_, _) => { App.Prefs.BubbleBorder = value; Changed(); };
            menu.Items.Add(item);
        }
        return menu;
    }

    private void Changed()
    {
        var center = new Point(Left + Width / 2, Top + Height / 2);
        App.SavePrefs();
        ApplyLook();
        Left = center.X - Width / 2;
        Top = center.Y - Height / 2;
        ContextMenu = BuildMenu();
    }

    private void ApplyLook()
    {
        double size = App.Prefs.BubbleSize;
        Width = size;
        Height = size;
        var radius = Layout.ShapeRadius(App.Prefs.BubbleShape, size / 2);
        frame.CornerRadius = new CornerRadius(radius);
        frame.Clip = new RectangleGeometry(new Rect(0, 0, size, size), radius, radius);
        ring.CornerRadius = new CornerRadius(radius);
        ring.BorderThickness = new Thickness(App.Prefs.BubbleBorder.A == 0 ? 0 : 1.5);
        ring.BorderBrush = new SolidColorBrush(ToColor(App.Prefs.BubbleBorder));
    }

    public static Color ToColor(Rgba c) => Color.FromArgb(c.A, c.R, c.G, c.B);
}

using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using PaolaScreenStudio.Core;

namespace PaolaScreenStudio;

/// <summary>Runs one recording from countdown to opening the editor.</summary>
internal sealed class RecordingController
{
    private const int HotkeyStop = 0x5051;
    private const int HotkeyPause = 0x5052;
    private readonly Ffmpeg ffmpeg;
    private readonly RecordingRequest request;
    private readonly MainWindow main;
    private readonly TaskCompletionSource<bool> done = new();
    private RecordingSession? session;
    private ControlBarWindow? bar;
    private CameraBubbleWindow? bubble;
    private HwndSource? hotkeySource;
    private bool busy;

    public RecordingController(Ffmpeg ffmpeg, RecordingRequest request, MainWindow main)
    {
        this.ffmpeg = ffmpeg;
        this.request = request;
        this.main = main;
    }

    public async Task RunAsync()
    {
        main.WindowState = WindowState.Minimized;
        if (App.Prefs.Countdown > 0 && !await CountdownWindow.RunAsync(App.Prefs.Countdown))
        {
            main.WindowState = WindowState.Normal;
            return;
        }

        session = new RecordingSession(ffmpeg, request, App.Prefs.ProjectsDirectory);
        if (request.Camera != null)
        {
            var window = new CameraBubbleWindow();
            bubble = window;
            window.Show();
            session.CameraFrame += bytes => window.Dispatcher.BeginInvoke(() => window.ShowFrame(Decode(bytes)));
        }
        bar = new ControlBarWindow(session);
        bar.PauseRequested += () => _ = TogglePauseAsync();
        bar.StopRequested += () => _ = FinishAsync();
        bar.CancelRequested += () => _ = CancelAsync();
        bar.Show();
        RegisterHotkeys();

        try
        {
            await session.StartAsync();
        }
        catch (Exception ex) when (ex is FfmpegException or IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            Cleanup();
            await session.CancelAsync();
            session.Dispose();
            main.WindowState = WindowState.Normal;
            MessageBox.Show(main, Strings.T("error.capture_failed") + "\n\n" + ex.Message, main.Title, MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }
        await done.Task;
    }

    private async Task TogglePauseAsync()
    {
        if (session == null || busy)
        {
            return;
        }
        busy = true;
        try
        {
            if (session.IsPaused)
            {
                await session.ResumeAsync();
            }
            else
            {
                await session.PauseAsync();
            }
            bar?.Refresh();
        }
        catch (FfmpegException ex)
        {
            MessageBox.Show(ex.Message, main.Title, MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            busy = false;
        }
    }

    private async Task FinishAsync()
    {
        if (session == null || busy)
        {
            return;
        }
        busy = true;
        Cleanup();
        var progress = new BusyWindow(Strings.T("record.saving"));
        progress.Show();
        try
        {
            var folder = await session.FinishAsync(new EditSettings
            {
                CameraShape = App.Prefs.BubbleShape,
                CameraBorderColor = App.Prefs.BubbleBorder,
            });
            progress.Close();
            main.WindowState = WindowState.Normal;
            main.RefreshProjectList();
            main.OpenProject(folder);
        }
        catch (Exception ex) when (ex is FfmpegException or IOException)
        {
            progress.Close();
            main.WindowState = WindowState.Normal;
            MessageBox.Show(main, Strings.T("error.save_failed", session.Folder) + "\n\n" + ex.Message, main.Title,
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            session.Dispose();
            done.TrySetResult(true);
        }
    }

    private async Task CancelAsync()
    {
        if (session == null || busy)
        {
            return;
        }
        busy = true;
        Cleanup();
        await session.CancelAsync();
        session.Dispose();
        main.WindowState = WindowState.Normal;
        done.TrySetResult(false);
    }

    private void RegisterHotkeys()
    {
        if (bar == null)
        {
            return;
        }
        var handle = new WindowInteropHelper(bar).Handle;
        hotkeySource = HwndSource.FromHwnd(handle);
        hotkeySource?.AddHook(OnHotkey);
        // Alt+Shift+S finishes, Alt+Shift+P pauses or resumes.
        Native.RegisterHotKey(handle, HotkeyStop, Native.MOD_ALT | Native.MOD_SHIFT | Native.MOD_NOREPEAT, 0x53);
        Native.RegisterHotKey(handle, HotkeyPause, Native.MOD_ALT | Native.MOD_SHIFT | Native.MOD_NOREPEAT, 0x50);
    }

    private IntPtr OnHotkey(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY)
        {
            if (wParam.ToInt32() == HotkeyStop)
            {
                _ = FinishAsync();
                handled = true;
            }
            else if (wParam.ToInt32() == HotkeyPause)
            {
                _ = TogglePauseAsync();
                handled = true;
            }
        }
        return IntPtr.Zero;
    }

    private void Cleanup()
    {
        if (bar != null)
        {
            var handle = new WindowInteropHelper(bar).Handle;
            Native.UnregisterHotKey(handle, HotkeyStop);
            Native.UnregisterHotKey(handle, HotkeyPause);
            hotkeySource?.RemoveHook(OnHotkey);
            bar.Close();
            bar = null;
        }
        bubble?.Close();
        bubble = null;
    }

    private static BitmapImage? Decode(byte[] bytes)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = new MemoryStream(bytes);
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception ex) when (ex is NotSupportedException or IOException or ArgumentException)
        {
            return null;
        }
    }
}

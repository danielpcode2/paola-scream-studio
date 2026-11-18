using System.Globalization;
using System.Text.Json.Serialization;

namespace PaolaScreenStudio.Core;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum Language { Spanish, English }

/// <summary>Spanish and English texts. <c>T(key, args)</c> formats with string.Format.</summary>
public static class Strings
{
    public static Language Current { get; set; } = SystemLanguage();

    public static Language SystemLanguage() =>
        CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "es" ? Language.Spanish : Language.English;

    public static string T(string key, params object[] args)
    {
        if (!Table.TryGetValue(key, out var pair))
        {
            return key;
        }
        var text = Current == Language.Spanish ? pair.Es : pair.En;
        return args.Length == 0 ? text : string.Format(CultureInfo.CurrentCulture, text, args);
    }

    public static readonly IReadOnlyDictionary<string, (string Es, string En)> Table = new Dictionary<string, (string, string)>
    {
        ["app.subtitle"] = ("Graba tu pantalla con zoom automático, cámara y efectos", "Record your screen with auto zoom, camera and effects"),
        ["settings.title"] = ("Ajustes", "Settings"),
        ["settings.ffmpeg"] = ("FFmpeg", "FFmpeg"),
        ["settings.ffmpeg_hint"] = ("Déjalo vacío para buscarlo junto a la app, en el PATH o en WinGet. Instálalo con: winget install Gyan.FFmpeg", "Leave empty to look next to the app, in PATH or in WinGet. Install it with: winget install Gyan.FFmpeg"),
        ["settings.projects"] = ("Carpeta de proyectos", "Projects folder"),
        ["settings.browse"] = ("Elegir…", "Browse…"),
        ["save"] = ("Guardar", "Save"),
        ["cancel"] = ("Cancelar", "Cancel"),
        ["ffmpeg.missing"] = ("No se encontró FFmpeg. Instálalo con «winget install Gyan.FFmpeg» y reinicia la app, o indica su ruta en Ajustes.", "FFmpeg was not found. Install it with \"winget install Gyan.FFmpeg\" and restart the app, or set its path in Settings."),

        ["record.what"] = ("Qué grabar", "What to record"),
        ["mode.display"] = ("Pantalla", "Display"),
        ["mode.window"] = ("Ventana", "Window"),
        ["mode.area"] = ("Área", "Area"),
        ["display.name"] = ("Pantalla {0}", "Display {0}"),
        ["area.select"] = ("Seleccionar área…", "Select area…"),
        ["area.none"] = ("Ninguna área seleccionada", "No area selected"),
        ["area.hint"] = ("Arrastra para elegir el área a grabar · Esc para cancelar", "Drag to choose the area to record · Esc to cancel"),
        ["record.camera"] = ("Cámara", "Camera"),
        ["record.microphone"] = ("Micrófono", "Microphone"),
        ["record.system_audio"] = ("Grabar el audio del sistema", "Record system audio"),
        ["record.countdown"] = ("Cuenta atrás (segundos)", "Countdown (seconds)"),
        ["record.start"] = ("● Empezar a grabar", "● Start recording"),
        ["record.hotkeys"] = ("Alt+Mayús+S termina la grabación · Alt+Mayús+P la pausa o la reanuda", "Alt+Shift+S finishes the recording · Alt+Shift+P pauses or resumes it"),
        ["record.finish"] = ("Terminar", "Finish"),
        ["record.pause"] = ("Pausar", "Pause"),
        ["record.resume"] = ("Reanudar", "Resume"),
        ["record.cancel"] = ("Cancelar grabación", "Cancel recording"),
        ["record.cancel_confirm"] = ("¿Descartar esta grabación?", "Discard this recording?"),
        ["record.saving"] = ("Guardando la grabación…", "Saving the recording…"),

        ["projects.title"] = ("Proyectos", "Projects"),
        ["projects.folder"] = ("Abrir carpeta", "Open folder"),
        ["projects.open"] = ("Abrir en el editor", "Open in editor"),
        ["projects.show"] = ("Mostrar en el Explorador", "Show in Explorer"),
        ["projects.delete"] = ("Eliminar", "Delete"),
        ["projects.delete_confirm"] = ("¿Enviar «{0}» a la papelera?", "Move \"{0}\" to the Recycle Bin?"),

        ["bubble.hint"] = ("Arrastra para mover · Clic derecho para tamaño, forma y borde", "Drag to move · Right-click for size, shape and border"),
        ["bubble.size"] = ("Tamaño", "Size"),
        ["bubble.size.small"] = ("Pequeño", "Small"),
        ["bubble.size.medium"] = ("Mediano", "Medium"),
        ["bubble.size.large"] = ("Grande", "Large"),
        ["bubble.size.xlarge"] = ("Muy grande", "Extra large"),
        ["camera.shape"] = ("Forma", "Shape"),
        ["camera.shape.circle"] = ("Círculo", "Circle"),
        ["camera.shape.rounded"] = ("Redondeado", "Rounded"),
        ["camera.shape.square"] = ("Cuadrado", "Square"),
        ["camera.border_color"] = ("Color del borde", "Border color"),
        ["camera.border.white"] = ("Blanco", "White"),
        ["camera.border.black"] = ("Negro", "Black"),
        ["camera.border.purple"] = ("Morado", "Purple"),
        ["camera.border.blue"] = ("Azul", "Blue"),
        ["camera.border.green"] = ("Verde", "Green"),
        ["camera.border.orange"] = ("Naranja", "Orange"),
        ["camera.border.pink"] = ("Rosa", "Pink"),
        ["camera.border.none"] = ("Sin borde", "No border"),
        ["camera.show"] = ("Mostrar cámara", "Show camera"),
        ["camera.corner"] = ("Esquina", "Corner"),
        ["camera.mirror"] = ("Efecto espejo", "Mirror"),
        ["color.hex"] = ("Color en hexadecimal, p. ej. #FF5C9E", "Hex color, e.g. #FF5C9E"),

        ["export.button"] = ("Exportar", "Export"),
        ["export.title"] = ("Exportar", "Export"),
        ["export.resolution"] = ("Resolución", "Resolution"),
        ["export.format"] = ("Formato", "Format"),
        ["export.quality"] = ("Calidad", "Quality"),
        ["export.quality.high"] = ("Alta", "High"),
        ["export.quality.medium"] = ("Media", "Medium"),
        ["export.quality.low"] = ("Baja (archivo pequeño)", "Low (small file)"),
        ["export.done"] = ("Video exportado. ¿Mostrarlo en el Explorador?", "Video exported. Show it in Explorer?"),
        ["export.failed"] = ("No se pudo exportar el video.", "The video could not be exported."),

        ["edit.undo"] = ("Deshacer", "Undo"),
        ["edit.redo"] = ("Rehacer", "Redo"),
        ["editor.saved"] = ("Guardado", "Saved"),
        ["editor.shortcuts"] = ("Atajos: Espacio reproducir · Z zoom · C corte · Supr eliminar · Ctrl+D duplicar · Ctrl+Z deshacer · Ctrl+E exportar", "Shortcuts: Space play · Z zoom · C cut · Del delete · Ctrl+D duplicate · Ctrl+Z undo · Ctrl+E export"),
        ["inspector.background"] = ("Fondo", "Background"),
        ["background.gradient"] = ("Degradado", "Gradient"),
        ["background.color"] = ("Color", "Color"),
        ["background.none"] = ("Sin fondo", "No background"),
        ["inspector.padding"] = ("Margen", "Padding"),
        ["inspector.corners"] = ("Esquinas", "Corners"),
        ["inspector.shadow"] = ("Sombra", "Shadow"),
        ["inspector.size"] = ("Tamaño", "Size"),
        ["inspector.zoom"] = ("Zoom", "Zoom"),
        ["inspector.clicks"] = ("Resaltar clics", "Highlight clicks"),
        ["inspector.clicks_hint"] = ("Los círculos de los clics se ven en el video exportado.", "Click rings appear in the exported video."),
        ["inspector.selected_zoom"] = ("Zoom seleccionado", "Selected zoom"),
        ["inspector.selected_cut"] = ("Corte seleccionado", "Selected cut"),
        ["cut.hint"] = ("Estos {0} no aparecerán en el video final.", "These {0} will not appear in the final video."),
        ["item.delete"] = ("Eliminar", "Delete"),
        ["item.duplicate"] = ("Duplicar", "Duplicate"),
        ["zoom.level"] = ("Zoom {0}×", "Zoom {0}×"),
        ["zoom.level_label"] = ("Nivel", "Level"),
        ["zoom.apply_all"] = ("Aplicar este nivel a todos los zooms", "Apply this level to all zooms"),
        ["zoom.follow"] = ("Seguir el cursor", "Follow the cursor"),
        ["zoom.fixed"] = ("Punto fijo", "Fixed point"),
        ["zoom.focus_x"] = ("Centro horizontal", "Horizontal center"),
        ["zoom.focus_y"] = ("Centro vertical", "Vertical center"),
        ["zoom.auto_level"] = ("Nivel del zoom automático", "Auto zoom level"),
        ["zoom.regenerate"] = ("Regenerar zooms desde {0} clics", "Regenerate zooms from {0} clicks"),
        ["timeline.video"] = ("Video", "Video"),
        ["timeline.zoom_hint"] = ("Haz clic aquí para añadir un zoom", "Click here to add a zoom"),
        ["timeline.add_zoom"] = ("Zoom", "Zoom"),
        ["timeline.add_cut"] = ("Corte", "Cut"),
        ["timeline.trim_start"] = ("Inicio aquí", "Start here"),
        ["timeline.trim_end"] = ("Fin aquí", "End here"),

        ["error.not_a_project"] = ("Esa carpeta no es un proyecto de Paola Screen Studio.", "That folder is not a Paola Screen Studio project."),
        ["error.empty_recording"] = ("La grabación está vacía.", "The recording is empty."),
        ["error.nothing_to_export"] = ("No queda nada que exportar: revisa el recorte y los cortes.", "Nothing left to export: check the trim and cuts."),
        ["error.capture_failed"] = ("No se pudo empezar a grabar.", "Recording could not start."),
        ["error.save_failed"] = ("No se pudo guardar la grabación. Los archivos originales siguen en:\n{0}", "The recording could not be saved. The original files are still in:\n{0}"),
        ["error.no_window"] = ("Elige una ventana abierta.", "Choose an open window."),
    };
}

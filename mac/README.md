# Mi Recorder

Grabador de pantalla nativo para macOS (Swift + SwiftUI + ScreenCaptureKit) con
zoom automático, cursor suavizado, fondos y exportación a MP4.

## Requisitos

- macOS 15 o superior
- Xcode 16 o superior (Swift 6 toolchain)

## Uso

```bash
./scripts/build-app.sh          # genera build/Mi Recorder.app
open "build/Mi Recorder.app"
```

Para desarrollo: `swift run` y `swift test`. También puedes abrir `Package.swift` en Xcode.

La primera grabación pide permisos de **Grabación de pantalla y audio del sistema** y
**Micrófono** (y **Cámara** si la activas). Después de concederlos, reinicia la app. Para que macOS no vuelva a pedirlos en cada
recompilación, crea una vez la identidad de firma local con `./scripts/create-signing-cert.sh`.

## Funciones

| Área | Qué hace |
| --- | --- |
| Menú de barra | Nueva grabación, grabar pantalla, ventana o área, ajustes, mostrar en el Dock, proyectos anteriores, abrir proyecto, abrir el último, idioma y salir. Mientras grabas: terminar, pausar o reanudar, reiniciar, crear marca, mostrar u ocultar controles y cancelar. |
| Barra de grabación | Pantalla, ventana o área; cámara (burbuja circular), micrófono con nivel, audio del sistema, carpeta de proyectos y opciones (cuenta atrás, ocultar iconos del escritorio y Dock, resaltar el área, notas del orador, widget de exportación rápida). |
| Grabación | ScreenCaptureKit a 60 fps en Retina. Pausar crea un segmento nuevo y el editor los une. Las marcas aparecen en la línea de tiempo. Las ventanas de la app nunca salen en la captura. |
| Después de grabar | Crear proyecto (con widget de exportación rápida o editor), exportar y copiar al portapapeles, o exportar a un archivo. |
| Editor | Línea de tiempo con carriles: zoom (seguir cursor o punto fijo), cortes y velocidad (1,5× a 8×), cambios de cámara (pantalla completa, grande, oculta) y anotaciones (texto, flecha, recuadro, foco, difuminado). Arrastrar para mover, bordes para cambiar duración, doble clic para añadir. |
| Efectos | Fondo degradado, color, imagen o fondo de pantalla (con desenfoque); marco de ventana macOS; cursor flecha, punto o halo, ocultar cuando está quieto y sonido de clic; atajos de teclado en pantalla; desenfocar el fondo de la cámara; intro y outro con transición. |
| Audio | Volumen, igualar volumen, reducir ruido (filtro + puerta de ruido) y música de fondo en bucle con fundido final. |
| Exportación | MP4 (H.264/HEVC con bitrate según la compresión), ProRes 422 o GIF; 24 a 60 FPS; 720p, 1080p o 4K, sin ampliar nunca la imagen. |
| Ajustes | General, Grabación, Edición, Exportación rápida, Atajos (globales y configurables) y Avanzado (diagnóstico local y permisos). |
| Idioma | Español e inglés, se cambia al instante desde Ajustes o desde el menú. |

Los proyectos se guardan en la carpeta configurada (por defecto `~/Movies/MiRecorder/<fecha>/`):
`recording.mov` (más `recording-2.mov`, … si pausaste), `camera.mov` si usaste la cámara y `project.json`.
Las exportaciones rápidas van a `<carpeta>/Exports/`.

También graba la pantalla de un iPhone o iPad conectado por USB (opción **Dispositivo**).

No incluido (requiere un servicio en la nube): enlaces compartibles y telemetría.

## Arquitectura

```
Sources/MiRecorder/
  App/        MiRecorderApp (menú de barra), AppModel (coordinador), WindowManager,
              Shortcuts (atajos globales Carbon), Localization (ES/EN)
  Model/      Project, Preferences, ProjectStore + PresetStore, ExportOptions
  Recording/  ScreenRecorder (destinos, segmentos, marcas), RecordingClock, CursorTracker,
              CameraRecorder, MicMonitor, RegionSelector
  Rendering/  CursorPath, Zoom, FrameCompositor (Core Image), VideoExporter (lector/escritor, GIF)
  UI/         RecordingToolbar, TargetPicker, RecordingPanels (widget, cuenta atrás, notas,
              exportación rápida, HUD), EditorView/Model, SettingsView, ProjectsView
```

El render no es destructivo: `RecordingTimeline` alinea en un `AVComposition` la pantalla,
sus pistas de audio y la cámara; `StudioVideoCompositor` (un `AVVideoCompositing` propio)
pasa ambos frames a `FrameCompositor`, que dibuja cursor, zoom, fondo, esquinas, sombra
y burbuja de cámara. La vista previa y la exportación usan el mismo pipeline.

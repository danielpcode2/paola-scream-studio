# Paola Screen Studio — Windows

Versión para Windows 10/11 hecha con **C# / .NET 8 + WPF**. Usa **FFmpeg** para grabar y exportar
y **SkiaSharp** para dibujar los efectos (fondo, esquinas, sombra, zoom, clics y cámara).

> Estado: el código compila y los tests del núcleo (incluida una exportación real con FFmpeg) pasan.
> La interfaz y la grabación aún no se han probado en un PC con Windows real.

## Qué hace

| Área | Funciones |
| --- | --- |
| Grabación | Pantalla completa (elige monitor), una ventana o un área que dibujas. 60 fps. Micrófono, audio del sistema (WASAPI) y cámara. Cuenta atrás, pausar/reanudar, terminar, cancelar. Atajos globales: **Alt+Mayús+S** termina, **Alt+Mayús+P** pausa. |
| Cámara | Burbuja flotante mientras grabas: arrástrala; clic derecho para tamaño, forma (círculo, redondeado, cuadrado) y color del borde. La barra de control, la cuenta atrás y la burbuja no salen en el video. |
| Editor | Vista previa en vivo, línea de tiempo con zooms (automáticos según tus clics, seguir cursor o punto fijo), cortes, recorte de inicio y fin, deshacer/rehacer y guardado automático. |
| Efectos | Fondo degradado, color o sin fondo; margen, esquinas redondeadas y sombra; burbuja de cámara con tamaño, forma, esquina, borde y espejo; círculos en los clics. |
| Exportación | MP4 (H.264 + AAC) o GIF; 720p a 4K sin ampliar nunca la imagen; 24/30/60 fps; calidad alta, media o baja. |
| Idioma | Español e inglés. |

Los proyectos se guardan en `Vídeos\Paola Screen Studio\<fecha>\` (`recording.mp4`, `camera.mp4`, `project.json`).
El formato del proyecto es propio de la versión de Windows (no se abre en la de Mac).

## Levantar la app en desarrollo

### 1. Requisitos

- Windows 10 versión 2004 o posterior, o Windows 11.
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (o Visual Studio 2022 con la carga
  de trabajo **Desarrollo de escritorio de .NET**).
- **FFmpeg**:

  ```powershell
  winget install Gyan.FFmpeg
  ```

  Cierra y vuelve a abrir la terminal para que quede en el `PATH`. La app también lo busca junto a
  su `.exe` y en la carpeta de WinGet, y en **Ajustes** puedes indicar la ruta a mano.

### 2. Clonar

```powershell
git clone git@github.com:danielpcode2/paola-scream-studio.git
cd paola-scream-studio\windows
```

### 3. Ejecutar

```powershell
dotnet run --project src\PaolaScreenStudio
```

O abre `PaolaScreenStudio.sln` en Visual Studio y pulsa **F5**.

Para abrir un proyecto directamente en el editor:

```powershell
dotnet run --project src\PaolaScreenStudio -- --open "C:\Users\<tú>\Videos\Paola Screen Studio\<carpeta>"
```

### 4. Tests

```powershell
dotnet test tests\PaolaScreenStudio.Core.Tests
```

Los tests de integración usan FFmpeg si está instalado (unen segmentos con audio y exportan MP4 y GIF).

### 5. Crear el `.exe`

```powershell
dotnet publish src\PaolaScreenStudio -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

Genera `publish\PaolaScreenStudio.exe`, que funciona sin instalar .NET. Copia `ffmpeg.exe` y
`ffprobe.exe` junto a él si el otro PC no tiene FFmpeg.

Cada push que toca `windows/` también compila, ejecuta los tests y publica el `.exe` en GitHub Actions
(workflow **Windows**, artefacto `PaolaScreenStudio-win-x64`).

### Compilar desde un Mac

El proyecto activa `EnableWindowsTargeting`, así que se puede **compilar** (no ejecutar) en macOS con
el SDK de .NET 8. Con un SDK más antiguo, solo para comprobar:

```bash
dotnet build src/PaolaScreenStudio -p:DotnetVersion=net7.0
dotnet test tests/PaolaScreenStudio.Core.Tests -p:DotnetVersion=net7.0
```

## Problemas comunes

| Problema | Solución |
| --- | --- |
| "No se encontró FFmpeg" | `winget install Gyan.FFmpeg`, reinicia la terminal o la app, o indica la ruta en Ajustes |
| No aparece la cámara o el micrófono | Ajustes de Windows › Privacidad › Cámara/Micrófono: permite el acceso a apps de escritorio |
| La ventana no se graba | Elige otra ventana o usa **Área**; algunas apps protegidas (DRM) salen en negro |
| Audio del sistema desfasado | Desactiva "Grabar el audio del sistema" y vuelve a probar; avísanos con el modelo de tarjeta de sonido |

## Arquitectura

```
windows/
  src/PaolaScreenStudio.Core/   (.NET, multiplataforma: se testea en Mac/Linux/Windows)
    Models, ProjectStore, Preferences, Strings (ES/EN)
    TimeMap (recorte + cortes), Zoom (planificador, cursor suavizado, edición de tramos)
    Layout (geometría común a vista previa y exportación), FrameRenderer (SkiaSharp)
    Ffmpeg (localizar, ejecutar, ffprobe, dispositivos DirectShow)
    RecordingFinalizer (une segmentos y mezcla micrófono + audio del sistema)
    Exporter (FFmpeg decodifica → SkiaSharp compone → FFmpeg codifica)
  src/PaolaScreenStudio/        (WPF, solo Windows)
    MainWindow (grabar + proyectos), RecordingController/Session (gdigrab, dshow, WASAPI, ratón)
    OverlayWindows (barra de control, cuenta atrás, selector de área), CameraBubbleWindow
    EditorWindow + TimelineControl, SettingsWindow, Native (Win32)
  tests/PaolaScreenStudio.Core.Tests
```

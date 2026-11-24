# ULTRA4K PREMIUM

Aplicación Android / Android TV / Google TV con interfaz premium en negro, verde biche y blanco.

## Archivos principales
- `index.html`: renovación visual integral premium; mantiene la lógica, navegación, listas, favoritos, historial, perfiles, ajustes y controles existentes.
- `capacitor.config.json`: nombre ULTRA4K y `appId` original `com.glystv.app` conservado para permitir actualizar la instalación existente.
- `build-glystv-v3.sh`: genera el proyecto Android y conserva los motores de reproducción integrados.
- `patch_tv.py`: registra la etiqueta y el launcher de Android TV / Google TV.
- `glystv-res.zip`, `icon.png`, `banner.png`, `banner-hd.png`: recursos gráficos de la aplicación y launcher.
- `.github/workflows/build.yml`: compilación automática de APK mediante GitHub Actions.

## Funciones conservadas según el código del proyecto
- Inicio de sesión por servidor y carga manual de listas M3U.
- TV en vivo, películas, series, categorías y búsqueda.
- Favoritos, historial, continuar viendo y perfiles.
- Configuración, modo infantil y bloqueo de contenido mediante PIN.
- Control remoto con foco visible para navegación Android TV / Google TV.
- Reproductor ExoPlayer (Media3 + FFmpeg) y VLC (libVLC), con selección automática o manual del motor.
- Opciones de audio, subtítulos, relación de aspecto, velocidad, saltos y reanudación disponibles según el reproductor.

## Compilar
1. Sube los archivos del proyecto conservando sus rutas al repositorio GitHub.
2. Ejecuta el workflow `Build ULTRA4K Android` desde Actions o realiza un push a `main`.
3. Descarga el APK generado en la publicación `apk-<número de ejecución>`.

Nota: esta entrega actualiza el diseño visual y documentación; no reemplaza servicios del proveedor, credenciales, URLs ni contenido de las listas. La compilación final debe ejecutarse en GitHub Actions para verificar el entorno Android completo.

## Novedades (v22)
- Foco/selección visible con el control: el elemento enfocado se pinta en verde lima claro con texto oscuro y aro blanco (antes quedaba negro sobre negro).
- Buscadores siempre visibles en modo TV: "Buscar carpeta…" arriba de las categorías y "Buscar…" arriba del contenido. OK sobre el campo abre el teclado; ABAJO vuelve a la lista. Menú/Amarillo salta al buscador.
- Actualización automática: la app consulta la última publicación de GitHub (tag `apk-N`), y si N es mayor que su número de compilación ofrece descargar e instalar el APK. También hay "Actualizar aplicación → Buscar" en Ajustes.
- Seguridad: index.html va cifrado dentro del APK (tools/protect.mjs), sin backups de Android, sin menú contextual/atajos de inspección, y el APK de actualización solo se descarga de GitHub y debe ser de la misma app.

## Pasos únicos para que las actualizaciones funcionen
1. Crear UNA llave de firma y guardarla (si la pierdes, nadie podrá actualizar sin desinstalar):
   keytool -genkeypair -v -keystore ultra4k.jks -alias ultra4k -keyalg RSA -keysize 2048 -validity 36500
2. En GitHub → Settings → Secrets and variables → Actions, crear:
   KEYSTORE_BASE64 (base64 -w0 ultra4k.jks), KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
3. Ejecutar el workflow. Cada ejecución sube un número (apk-N); la app instalada avisa cuando exista uno mayor.
4. La primera vez, quien tenga instalada una versión anterior (firmada con otra llave) debe desinstalarla una vez.
5. En el equipo, Android pedirá activar "Instalar apps desconocidas" para ULTRA4K la primera vez que se actualice.
Compilación local: BUILD_NUMBER=<n> KEYSTORE_FILE=... KEYSTORE_PASSWORD=... KEY_ALIAS=... KEY_PASSWORD=... bash build-glystv-v3.sh  (salida: dist/ULTRA4K.apk)

## Novedades traídas de GLYSTV-PRO
- Opciones del reproductor → "Buffer": Rápido / Normal / Estable. Se guarda y se aplica en la siguiente reproducción.
  Normal = el comportamiento anterior. Estable usa más búfer (50/120 s) con tope de 64 MB para TV box con poca memoria.
- Reproductor: si el decodificador por hardware falla, prueba otro automáticamente (HEVC, VP9, AV1…).
- Inicio de sesión: botón "↔ Mover QR" para poner el QR a la izquierda o a la derecha (se recuerda).
- Películas y Series: al escribir 2 o más letras en la lupa se busca en TODO el catálogo, no solo en la carpeta abierta.
  Al borrar el texto o cerrar la lupa se vuelve a la carpeta que estaba abierta.

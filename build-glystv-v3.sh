#!/usr/bin/env bash
set -euo pipefail

# 1) Web de la app
rm -rf www android ios
mkdir www
cp index.html www/
[ -f logo.png ] && cp logo.png www/

# 1.1) Número de compilación (lo usa la app para saber si hay una versión más nueva)
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
VC="$BUILD_NUMBER"; [ "$VC" -ge 1 ] 2>/dev/null || VC=1
sed -i "s/__BUILD__/${BUILD_NUMBER}/" www/index.html
# 1.2) Ocultar el código de index.html dentro del APK (cifrado + cargador)
if [ -f tools/protect.mjs ]; then node tools/protect.mjs www/index.html; fi

# 2) Proyecto Android
npx cap add android

# 2.1) Proyecto iOS
# El proyecto iOS se prepara aquí; la compilación y firma final requieren macOS/Xcode.
IOS_READY=0
if npx cap add ios; then
  IOS_READY=1
  echo "Proyecto iOS creado correctamente."

  # Permitir fuentes HTTP si la aplicación IPTV las utiliza.
  IOS_PLIST="ios/App/App/Info.plist"
  if [ -f "$IOS_PLIST" ]; then
    python3 - "$IOS_PLIST" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if "NSAppTransportSecurity" not in s:
    marker = "</dict>"
    block = (
        "\t<key>NSAppTransportSecurity</key>\n"
        "\t<dict>\n"
        "\t\t<key>NSAllowsArbitraryLoads</key>\n"
        "\t\t<true/>\n"
        "\t</dict>\n"
    )
    s = s.replace(marker, block + marker, 1)
    p.write_text(s, encoding="utf-8")
PY
  fi
else
  echo "AVISO: no fue posible crear iOS en este entorno. Android continuará normalmente."
fi
unzip -oq glystv-res.zip -d android/app/src/main/res
PKG=android/app/src/main/java/com/glystv/app
MAN=android/app/src/main/AndroidManifest.xml

cat > $PKG/MainActivity.java <<'JAVA'
package com.glystv.app;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    registerPlugin(NativePlayerPlugin.class);
    registerPlugin(RemoteSetupPlugin.class);
    registerPlugin(ApkUpdaterPlugin.class);
    super.onCreate(savedInstanceState);
  }

  @Override
  public void onBackPressed() {
    NativePlayerPlugin p = NativePlayerPlugin.instance;
    if (p != null && p.handleBack()) return;
    try {
      android.webkit.WebView wv = getBridge().getWebView();
      if (wv != null && wv.canGoBack()) {
        wv.goBack();
        return;
      }
    } catch (Exception e) { /* si falla, pregunta si quiere salir */ }
    new android.app.AlertDialog.Builder(this)
        .setTitle("Salir de ULTRA4K")
        .setMessage("¿Quieres salir de la aplicación?")
        .setPositiveButton("Sí", (d, w) -> finishAffinity())
        .setNegativeButton("No", null)
        .show();
  }
}
JAVA

cat > $PKG/ApkUpdaterPlugin.java <<'UPDJAVA'
package com.glystv.app;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import android.content.pm.PackageInfo;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/** Descarga el APK nuevo desde GitHub Releases y abre el instalador de Android. */
@CapacitorPlugin(name = "ApkUpdater")
public class ApkUpdaterPlugin extends Plugin {

  private static boolean okHost(String h) {
    if (h == null) return false;
    h = h.toLowerCase();
    return h.equals("github.com") || h.endsWith(".github.com") || h.endsWith(".githubusercontent.com");
  }

  @PluginMethod
  public void install(final PluginCall call) {
    final String url = call.getString("url");
    if (url == null || !url.startsWith("https://")) { call.reject("URL de actualización no válida"); return; }
    try {
      if (!okHost(new URL(url).getHost())) { call.reject("Origen de actualización no permitido"); return; }
    } catch (Exception e) { call.reject("URL de actualización no válida"); return; }

    if (Build.VERSION.SDK_INT >= 26 && !getContext().getPackageManager().canRequestPackageInstalls()) {
      Intent s = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getContext().getPackageName()));
      s.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
      getContext().startActivity(s);
      call.reject("Activa \"Permitir instalar apps\" para ULTRA4K y pulsa Actualizar otra vez");
      return;
    }

    new Thread(() -> {
      HttpURLConnection c = null;
      try {
        File dir = new File(getContext().getCacheDir(), "updates");
        if (!dir.exists()) dir.mkdirs();
        File out = new File(dir, "ULTRA4K.apk");
        if (out.exists()) out.delete();

        c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(20000);
        c.setReadTimeout(30000);
        c.connect();
        if (!okHost(c.getURL().getHost())) throw new Exception("Redirección no permitida");
        if (c.getResponseCode() != 200) throw new Exception("HTTP " + c.getResponseCode());
        long total = c.getContentLengthLong();
        long done = 0;
        int last = -1;
        try (InputStream in = c.getInputStream(); FileOutputStream os = new FileOutputStream(out)) {
          byte[] buf = new byte[32768];
          int n;
          while ((n = in.read(buf)) > 0) {
            os.write(buf, 0, n);
            done += n;
            if (total > 0) {
              int p = (int) (done * 100 / total);
              if (p != last) {
                last = p;
                JSObject o = new JSObject();
                o.put("percent", p);
                notifyListeners("progress", o);
              }
            }
          }
        }
        if (out.length() < 1024 * 1024) throw new Exception("Archivo incompleto");

        // Debe ser nuestra misma app (Android además exige la misma firma)
        PackageInfo pi = getContext().getPackageManager().getPackageArchiveInfo(out.getAbsolutePath(), 0);
        if (pi == null || !getContext().getPackageName().equals(pi.packageName)) throw new Exception("El APK descargado no es de ULTRA4K");

        Uri uri = FileProvider.getUriForFile(getContext(), getContext().getPackageName() + ".fileprovider", out);
        Intent i = new Intent(Intent.ACTION_VIEW);
        i.setDataAndType(uri, "application/vnd.android.package-archive");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        getContext().startActivity(i);
        call.resolve();
      } catch (Exception e) {
        call.reject(e.getMessage() == null ? "No se pudo descargar la actualización" : e.getMessage());
      } finally {
        if (c != null) c.disconnect();
      }
    }).start();
  }
}
UPDJAVA

mkdir -p android/app/src/main/res/xml
cat > android/app/src/main/res/xml/file_paths.xml <<'XMLPATHS'
<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <external-path name="my_images" path="." />
    <cache-path name="my_cache_images" path="." />
</paths>
XMLPATHS

cat > $PKG/NativePlayerPlugin.java <<'JAVA'
package com.glystv.app;

import android.content.Intent;
import android.graphics.Color;
import android.view.Gravity;
import android.view.KeyEvent;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.Tracks;
import androidx.media3.ui.AspectRatioFrameLayout;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.ui.PlayerView;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "NativePlayer")
public class NativePlayerPlugin extends Plugin {
  static NativePlayerPlugin instance;

  private ExoPlayer player;
  private PlayerView pview;
  private FrameLayout holder;
  private boolean full = false;
  private int rx = 0, ry = 0, rw = 400, rh = 225;
  private String curUrl = "";
  private boolean triedTs = false;

  /* Controles en pantalla completa (TV en vivo) */
  private LinearLayout ctl;
  private TextView tTitle, tAspect, tAudio, bFav, bFull;
  private String title = "";
  private boolean fav = false, muted = false;
  private int aspectMode = 0, audioIdx = -1;
  private String audioName = "";
  private static final String[] ASP = {"Normal", "Zoom", "Estirar"};
  private final Runnable hideCtl = new Runnable() {
    @Override public void run() {
      if (ctl != null) ctl.setVisibility(View.GONE);
      if (tTitle != null) tTitle.setVisibility(View.GONE);
      if (holder != null && full) holder.requestFocus();
    }
  };

  @Override
  public void load() {
    instance = this;
  }

  @PluginMethod
  public void play(PluginCall call) {
    String url = call.getString("url");
    if (url == null) { call.reject("Falta la url"); return; }
    String engine = call.getString("engine", "auto");
    Intent i = new Intent(getContext(),
        "vlc".equals(engine) ? VlcPlayerActivity.class : PlayerActivity.class);
    i.putExtra("engine", engine);
    i.putExtra("url", url);
    i.putExtra("title", call.getString("title", ""));
    i.putExtra("urls", call.getString("urls", ""));
    i.putExtra("titles", call.getString("titles", ""));
    i.putExtra("idx", call.getInt("idx", 0));
    getActivity().startActivity(i);
    call.resolve();
  }

  @PluginMethod
  public void preview(final PluginCall call) {
    final String url = call.getString("url");
    if (url == null) { call.reject("Falta la url"); return; }
    final int x = call.getInt("x", 0);
    final int y = call.getInt("y", 0);
    final int w = call.getInt("w", 400);
    final int h = call.getInt("h", 225);
    getActivity().runOnUiThread(() -> {
      try {
        ensurePlayer();
        String pt = call.getString("title");
        if (pt != null) title = pt;
        rx = x; ry = y; rw = w; rh = h;
        attach();
        if (!url.equals(curUrl)) {
          curUrl = url;
          triedTs = false;
          start(url);
        } else {
          player.play();
        }
        call.resolve();
      } catch (Exception e) {
        call.reject(String.valueOf(e.getMessage()));
      }
    });
  }

  @PluginMethod
  public void place(final PluginCall call) {
    final int x = call.getInt("x", 0);
    final int y = call.getInt("y", 0);
    final int w = call.getInt("w", 400);
    final int h = call.getInt("h", 225);
    getActivity().runOnUiThread(() -> {
      rx = x; ry = y; rw = w; rh = h;
      if (holder != null && holder.getParent() != null && !full) applyLayout();
      call.resolve();
    });
  }

  @PluginMethod
  public void fullscreen(final PluginCall call) {
    final boolean on = Boolean.TRUE.equals(call.getBoolean("on", false));
    final String t = call.getString("title");
    final boolean hasFav = call.hasOption("fav");
    final boolean f = Boolean.TRUE.equals(call.getBoolean("fav", false));
    getActivity().runOnUiThread(() -> {
      if (t != null) title = t;
      if (hasFav) fav = f;
      setFull(on);
      call.resolve();
    });
  }

  @PluginMethod
  public void setFav(final PluginCall call) {
    final boolean f = Boolean.TRUE.equals(call.getBoolean("on", false));
    getActivity().runOnUiThread(() -> {
      fav = f;
      updateLabels();
      call.resolve();
    });
  }

  @PluginMethod
  public void hidePreview(final PluginCall call) {
    getActivity().runOnUiThread(() -> {
      hide();
      call.resolve();
    });
  }

  boolean handleBack() {
    if (full) {
      closeFull();
      return true;
    }
    return false;
  }

  @Override
  protected void handleOnPause() {
    if (player != null) player.pause();
  }

  @Override
  protected void handleOnDestroy() {
    if (player != null) {
      player.release();
      player = null;
    }
    instance = null;
  }

  private void ensurePlayer() {
    if (player != null) return;
    DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
        .setUserAgent("VLC/3.0.18 LibVLC/3.0.18")
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(15000)
        .setReadTimeoutMs(15000);
    DefaultRenderersFactory rf = new DefaultRenderersFactory(getActivity())
        .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER);
    player = new ExoPlayer.Builder(getActivity(), rf)
        .setMediaSourceFactory(new DefaultMediaSourceFactory(getActivity()).setDataSourceFactory(http))
        .build();
    player.addListener(new Player.Listener() {
      @Override
      public void onPlayerError(PlaybackException e) {
        if (!triedTs && curUrl.contains(".m3u8")) {
          triedTs = true;
          curUrl = curUrl.replace(".m3u8", ".ts");
          start(curUrl);
        } else {
          JSObject o = new JSObject();
          o.put("message", describe(e));
          notifyListeners("error", o);
        }
      }
    });
    pview = new PlayerView(getActivity());
    pview.setUseController(false);
    pview.setPlayer(player);
    holder = new FrameLayout(getActivity());
    holder.setBackgroundColor(Color.BLACK);
    holder.addView(pview, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    holder.setOnClickListener(v -> {
      if (full) {
        if (ctl != null && ctl.getVisibility() == View.VISIBLE) hideCtl.run();
        else showCtl();
      } else {
        notifyListeners("tap", new JSObject());
      }
    });
    holder.setOnKeyListener((v, code, ev) -> {
      if (full && ev.getAction() == KeyEvent.ACTION_DOWN && ctl != null
          && ctl.getVisibility() != View.VISIBLE && code != KeyEvent.KEYCODE_BACK) {
        showCtl();
        if (bFull != null) bFull.requestFocus();
        return true;
      }
      return false;
    });
    buildOverlay();
  }

  private void attach() {
    if (holder.getParent() == null) {
      ViewGroup root = getActivity().findViewById(android.R.id.content);
      root.addView(holder);
    }
    applyLayout();
  }

  private void applyLayout() {
    if (holder == null) return;
    FrameLayout.LayoutParams lp;
    if (full) {
      lp = new FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
    } else {
      lp = new FrameLayout.LayoutParams(rw, rh);
      lp.gravity = Gravity.TOP | Gravity.START;
      lp.leftMargin = rx;
      lp.topMargin = ry;
    }
    holder.setLayoutParams(lp);
  }

  private void setFull(boolean on) {
    full = on;
    applyLayout();
    if (holder != null) holder.setFocusable(on);
    if (tTitle != null) {
      tTitle.setText(title);
      if (!on) tTitle.setVisibility(View.GONE);
    }
    if (ctl != null) {
      holder.removeCallbacks(hideCtl);
      if (on) {
        updateLabels();
        showCtl();
        if (bFull != null) bFull.requestFocus();
      } else {
        ctl.setVisibility(View.GONE);
      }
    }
    View d = getActivity().getWindow().getDecorView();
    if (on) {
      d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
          | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    } else {
      d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE);
    }
  }

  private void hide() {
    if (full) setFull(false);
    if (holder != null && holder.getParent() != null) {
      ((ViewGroup) holder.getParent()).removeView(holder);
    }
    if (player != null) {
      player.stop();
      player.clearMediaItems();
    }
    curUrl = "";
  }

  private void start(String url) {
    audioIdx = -1;
    audioName = "";
    try {
      player.setTrackSelectionParameters(player.getTrackSelectionParameters()
          .buildUpon().clearOverridesOfType(C.TRACK_TYPE_AUDIO).build());
    } catch (Exception e) { /* opcional */ }
    updateLabels();
    player.setMediaItem(MediaItem.fromUri(url));
    player.prepare();
    player.play();
  }

  /* ===== Controles de pantalla completa: Volver, Opciones, Pantalla, Favorito, Audio, Aspecto ===== */
  private android.graphics.drawable.Drawable btnBg(boolean focus, boolean hl) {
    android.graphics.drawable.GradientDrawable g = new android.graphics.drawable.GradientDrawable();
    g.setCornerRadius(26);
    if (focus) {
      g.setColor(Color.rgb(140, 198, 63));
      g.setStroke(4, Color.WHITE);
    } else if (hl) {
      g.setColor(Color.rgb(62, 104, 28));
      g.setStroke(2, Color.rgb(168, 216, 78));
    } else {
      g.setColor(Color.argb(215, 12, 20, 10));
      g.setStroke(2, Color.argb(130, 94, 158, 42));
    }
    return g;
  }

  private TextView mkBtn(String text, boolean hl) {
    TextView b = new TextView(getActivity());
    b.setText(text);
    b.setTextColor(Color.WHITE);
    b.setTextSize(16);
    b.setGravity(Gravity.CENTER);
    b.setSingleLine(true);
    b.setPadding(24, 22, 24, 22);
    b.setFocusable(true);
    b.setClickable(true);
    b.setTag(Boolean.valueOf(hl));
    b.setBackground(btnBg(false, hl));
    b.setOnFocusChangeListener((view, f) -> {
      view.setBackground(btnBg(f, Boolean.TRUE.equals(view.getTag())));
      if (f) showCtl();
    });
    return b;
  }

  private LinearLayout.LayoutParams lp(int w, float wt, int m) {
    LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, ViewGroup.LayoutParams.WRAP_CONTENT, wt);
    p.setMargins(m, m, m, m);
    return p;
  }

  private void buildOverlay() {
    android.app.Activity a = getActivity();

    tTitle = new TextView(a);
    tTitle.setTextColor(Color.WHITE);
    tTitle.setTextSize(22);
    tTitle.setSingleLine(true);
    tTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
    tTitle.setShadowLayer(6, 2, 2, Color.BLACK);
    tTitle.setPadding(48, 32, 48, 64);
    tTitle.setBackground(new android.graphics.drawable.GradientDrawable(
        android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
        new int[]{Color.argb(225, 0, 0, 0), Color.TRANSPARENT}));
    tTitle.setVisibility(View.GONE);
    holder.addView(tTitle, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP));

    ctl = new LinearLayout(a);
    ctl.setOrientation(LinearLayout.VERTICAL);
    ctl.setPadding(40, 90, 40, 28);
    ctl.setBackground(new android.graphics.drawable.GradientDrawable(
        android.graphics.drawable.GradientDrawable.Orientation.BOTTOM_TOP,
        new int[]{Color.argb(235, 0, 0, 0), Color.TRANSPARENT}));
    ctl.setVisibility(View.GONE);

    LinearLayout pills = new LinearLayout(a);
    pills.setOrientation(LinearLayout.HORIZONTAL);
    pills.setGravity(Gravity.END);
    tAspect = mkBtn("", false);
    tAudio = mkBtn("", false);
    pills.addView(tAspect, lp(ViewGroup.LayoutParams.WRAP_CONTENT, 0f, 8));
    pills.addView(tAudio, lp(ViewGroup.LayoutParams.WRAP_CONTENT, 0f, 8));
    ctl.addView(pills, new LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

    TextView tTime = new TextView(a);
    tTime.setText("● EN VIVO");
    tTime.setTextColor(Color.rgb(255, 80, 90));
    tTime.setTextSize(16);
    tTime.setShadowLayer(4, 1, 1, Color.BLACK);
    tTime.setPadding(12, 12, 12, 12);
    ctl.addView(tTime, new LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));

    LinearLayout row = new LinearLayout(a);
    row.setOrientation(LinearLayout.HORIZONTAL);
    TextView bBack = mkBtn("‹ Volver", false);
    TextView bOpt = mkBtn("⚙ Opciones", false);
    bFull = mkBtn("⛶ Pantalla", true);
    bFav = mkBtn("☆ Favorito", false);
    row.addView(bBack, lp(0, 1f, 8));
    row.addView(bOpt, lp(0, 1f, 8));
    row.addView(bFull, lp(0, 1f, 8));
    row.addView(bFav, lp(0, 1f, 8));
    ctl.addView(row, new LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

    bBack.setOnClickListener(view -> closeFull());
    bFull.setOnClickListener(view -> closeFull());
    bOpt.setOnClickListener(view -> showOptions());
    bFav.setOnClickListener(view -> {
      notifyListeners("fav", new JSObject());
      showCtl();
    });
    tAspect.setOnClickListener(view -> cycleAspect());
    tAudio.setOnClickListener(view -> cycleAudio());

    holder.addView(ctl, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));
    updateLabels();
  }

  private void showCtl() {
    if (ctl == null || holder == null) return;
    ctl.setVisibility(View.VISIBLE);
    if (tTitle != null && full) tTitle.setVisibility(View.VISIBLE);
    holder.removeCallbacks(hideCtl);
    holder.postDelayed(hideCtl, 5000);
  }

  private void closeFull() {
    setFull(false);
    JSObject o = new JSObject();
    o.put("on", false);
    notifyListeners("fullscreen", o);
  }

  private void updateLabels() {
    if (tAspect != null) tAspect.setText("▣ " + ASP[aspectMode]);
    if (tAudio != null) {
      tAudio.setText(muted ? "🔇 Silenciado"
          : "🔊 " + (audioName.isEmpty() ? "Audio Automática" : audioName));
    }
    if (bFav != null) bFav.setText(fav ? "★ Favorito" : "☆ Favorito");
  }

  private void cycleAspect() {
    aspectMode = (aspectMode + 1) % ASP.length;
    if (pview != null) {
      int m = aspectMode == 1 ? AspectRatioFrameLayout.RESIZE_MODE_ZOOM
          : aspectMode == 2 ? AspectRatioFrameLayout.RESIZE_MODE_FILL
          : AspectRatioFrameLayout.RESIZE_MODE_FIT;
      pview.setResizeMode(m);
    }
    updateLabels();
    showCtl();
  }

  private void toggleMute() {
    muted = !muted;
    if (player != null) player.setVolume(muted ? 0f : 1f);
    updateLabels();
    showCtl();
  }

  private void cycleAudio() {
    if (player == null) return;
    java.util.ArrayList<Tracks.Group> au = new java.util.ArrayList<>();
    for (Tracks.Group g : player.getCurrentTracks().getGroups()) {
      if (g.getType() == C.TRACK_TYPE_AUDIO && g.length > 0 && g.isTrackSupported(0)) au.add(g);
    }
    if (au.size() < 2) {
      toggleMute();
      return;
    }
    audioIdx = (audioIdx + 1) % au.size();
    Tracks.Group g = au.get(audioIdx);
    player.setTrackSelectionParameters(player.getTrackSelectionParameters().buildUpon()
        .setOverrideForType(new TrackSelectionOverride(g.getMediaTrackGroup(), 0)).build());
    Format f = g.getTrackFormat(0);
    audioName = f.label != null ? f.label : (f.language != null ? f.language : "Pista " + (audioIdx + 1));
    if (muted) { muted = false; player.setVolume(1f); }
    updateLabels();
    showCtl();
  }

  private void showOptions() {
    showCtl();
    final String[] items = {
        "Relación de aspecto: " + ASP[aspectMode],
        "Audio: " + (audioName.isEmpty() ? "Automática" : audioName),
        muted ? "Activar sonido" : "Silenciar"
    };
    new android.app.AlertDialog.Builder(getActivity())
        .setTitle("Opciones")
        .setItems(items, (d, which) -> {
          if (which == 0) cycleAspect();
          else if (which == 1) cycleAudio();
          else toggleMute();
        })
        .show();
  }

  private static String describe(PlaybackException e) {
    Throwable c = e.getCause();
    if (c instanceof HttpDataSource.InvalidResponseCodeException) {
      return "HTTP " + ((HttpDataSource.InvalidResponseCodeException) c).responseCode;
    }
    return e.getErrorCodeName();
  }
}
JAVA

cat > $PKG/VlcPlayerActivity.java <<'JAVA'
package com.glystv.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Locale;
import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;
import org.videolan.libvlc.util.VLCVideoLayout;

/* Reproductor VLC (libVLC) de ULTRA4K: todos los códecs y protocolos de VLC */
public class VlcPlayerActivity extends Activity {
  private static final int BICHE = Color.rgb(140, 198, 63);
  private static final String PREFS = "glystv_resume";

  private LibVLC libVLC;
  private MediaPlayer mp;
  private VLCVideoLayout vlcLayout;
  private TextView status, ttl, tTime, bNext;
  private SeekBar seek;
  private LinearLayout bar;
  private final Handler h = new Handler(Looper.getMainLooper());
  private String url = "";
  private String[] qUrls = new String[0];
  private String[] qTitles = new String[0];
  private int qIdx = 0;
  private int skipMs = 10000;
  private boolean barOn = false, retried = false, resumed = false, userSeek = false;
  private long length = 0;
  private int aspect = 0, rateIdx = 1;

  private static final MediaPlayer.ScaleType[] SC = {
    MediaPlayer.ScaleType.SURFACE_BEST_FIT, MediaPlayer.ScaleType.SURFACE_FIT_SCREEN,
    MediaPlayer.ScaleType.SURFACE_FILL, MediaPlayer.ScaleType.SURFACE_16_9,
    MediaPlayer.ScaleType.SURFACE_4_3 };
  private static final String[] SCN = { "Ajustar", "Llenar pantalla", "Estirar", "16:9", "4:3" };
  private static final float[] RATES = { 0.75f, 1f, 1.25f, 1.5f, 2f };

  private final Runnable hideBar = () -> showBar(false);
  private final Runnable tick = new Runnable() {
    @Override public void run() {
      updateProgress();
      h.postDelayed(this, 1000);
    }
  };

  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    getWindow().getDecorView().setSystemUiVisibility(
        View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);

    url = getIntent().getStringExtra("url");
    if (url == null) { finish(); return; }
    String u = getIntent().getStringExtra("urls");
    String t = getIntent().getStringExtra("titles");
    if (u != null && !u.isEmpty()) {
      qUrls = u.split("\n");
      qTitles = t == null ? new String[0] : t.split("\n");
      qIdx = getIntent().getIntExtra("idx", 0);
    }
    skipMs = getSharedPreferences("glystv_prefs", MODE_PRIVATE).getInt("skip", 10000);

    FrameLayout root = new FrameLayout(this);
    root.setBackgroundColor(Color.BLACK);
    vlcLayout = new VLCVideoLayout(this);
    root.addView(vlcLayout, new FrameLayout.LayoutParams(-1, -1));

    ttl = new TextView(this);
    ttl.setTextColor(Color.WHITE);
    ttl.setTextSize(20);
    ttl.setSingleLine(true);
    ttl.setEllipsize(android.text.TextUtils.TruncateAt.END);
    ttl.setShadowLayer(6, 2, 2, Color.BLACK);
    ttl.setPadding(32, 24, 32, 12);
    ttl.setText(getIntent().getStringExtra("title") == null ? "" : getIntent().getStringExtra("title"));
    ttl.setVisibility(View.GONE);
    root.addView(ttl, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP | Gravity.START));

    status = new TextView(this);
    status.setTextColor(Color.WHITE);
    status.setTextSize(14);
    status.setShadowLayer(5, 2, 2, Color.BLACK);
    status.setPadding(32, 24, 32, 24);
    FrameLayout.LayoutParams stLp = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START);
    stLp.topMargin = 90;
    root.addView(status, stLp);

    /* Barra inferior: progreso + botones */
    bar = new LinearLayout(this);
    bar.setOrientation(LinearLayout.VERTICAL);
    bar.setBackgroundColor(Color.argb(200, 8, 12, 6));
    bar.setPadding(32, 16, 32, 20);
    LinearLayout line = new LinearLayout(this);
    line.setOrientation(LinearLayout.HORIZONTAL);
    line.setGravity(Gravity.CENTER_VERTICAL);
    seek = new SeekBar(this);
    seek.setKeyProgressIncrement(skipMs);
    /* Solo lo reproducido en verde; el resto gris (antes el filtro teñía todo el fondo) */
    seek.setProgressTintList(android.content.res.ColorStateList.valueOf(BICHE));
    seek.setProgressBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.argb(90, 255, 255, 255)));
    seek.setSecondaryProgressTintList(android.content.res.ColorStateList.valueOf(Color.argb(140, 255, 255, 255)));
    seek.setThumbTintList(android.content.res.ColorStateList.valueOf(Color.WHITE));
    seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
      @Override public void onProgressChanged(SeekBar s, int p, boolean fromUser) {
        if (fromUser && mp != null) { mp.setTime(p); armHide(); }
      }
      @Override public void onStartTrackingTouch(SeekBar s) { userSeek = true; }
      @Override public void onStopTrackingTouch(SeekBar s) { userSeek = false; }
    });
    line.addView(seek, new LinearLayout.LayoutParams(0, -2, 1f));
    tTime = new TextView(this);
    tTime.setTextColor(Color.WHITE);
    tTime.setTextSize(14);
    tTime.setPadding(24, 0, 0, 0);
    line.addView(tTime, new LinearLayout.LayoutParams(-2, -2));
    bar.addView(line, new LinearLayout.LayoutParams(-1, -2));

    LinearLayout btns = new LinearLayout(this);
    btns.setOrientation(LinearLayout.HORIZONTAL);
    btns.setGravity(Gravity.CENTER);
    btns.addView(btn("⏪ 10s", x -> seekBy(-skipMs)));
    btns.addView(btn("⏯ Pausa", x -> togglePause()));
    btns.addView(btn("10s ⏩", x -> seekBy(skipMs)));
    btns.addView(btn("Audio", x -> pickAudio()));
    btns.addView(btn("Subtítulos", x -> pickSubs()));
    btns.addView(btn("Aspecto", x -> pickAspect()));
    btns.addView(btn("Velocidad", x -> pickRate()));
    bNext = btn("Siguiente ›", x -> playNext());
    bNext.setVisibility(qIdx + 1 < qUrls.length ? View.VISIBLE : View.GONE);
    btns.addView(bNext);
    bar.addView(btns, new LinearLayout.LayoutParams(-1, -2));
    bar.setVisibility(View.GONE);
    root.addView(bar, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

    root.setOnClickListener(x -> showBar(!barOn));
    setContentView(root);

    ArrayList<String> o = new ArrayList<>();
    o.add("--network-caching=1500");
    o.add("--live-caching=1500");
    o.add("--http-reconnect");
    o.add("--avcodec-hw=any");
    o.add("--audio-time-stretch");
    libVLC = new LibVLC(this, o);
    mp = new MediaPlayer(libVLC);
    mp.attachViews(vlcLayout, null, true, false);
    mp.setEventListener(this::onVlcEvent);
    start();
    h.postDelayed(tick, 1000);
  }

  private TextView btn(String txt, View.OnClickListener l) {
    final TextView b = new TextView(this);
    b.setText(txt);
    b.setTextColor(Color.WHITE);
    b.setTextSize(14);
    b.setGravity(Gravity.CENTER);
    b.setPadding(22, 12, 22, 12);
    b.setFocusable(true);
    b.setClickable(true);
    b.setOnFocusChangeListener((v, f) -> b.setBackgroundColor(f ? Color.argb(190, 94, 158, 42) : Color.TRANSPARENT));
    b.setOnClickListener(x -> { armHide(); l.onClick(x); });
    return b;
  }

  private void start() {
    status.setText("Cargando con VLC…");
    Media m = new Media(libVLC, Uri.parse(url));
    m.setHWDecoderEnabled(true, false);
    m.addOption(":http-user-agent=VLC/3.0.18 LibVLC/3.0.18");
    m.addOption(":network-caching=1500");
    mp.setMedia(m);
    m.release();
    mp.play();
  }

  private void onVlcEvent(MediaPlayer.Event e) {
    switch (e.type) {
      case MediaPlayer.Event.Playing:
        status.setText("");
        if (!resumed) {
          resumed = true;
          long saved = getSharedPreferences(PREFS, MODE_PRIVATE).getLong(key(), 0);
          if (saved > 5000) mp.setTime(saved);
        }
        break;
      case MediaPlayer.Event.Buffering:
        if (e.getBuffering() < 100f) status.setText("Cargando " + (int) e.getBuffering() + "%");
        else status.setText("");
        break;
      case MediaPlayer.Event.LengthChanged:
        length = e.getLengthChanged();
        break;
      case MediaPlayer.Event.EncounteredError:
        if (!retried && url.contains(".m3u8")) {
          retried = true;
          url = url.replace(".m3u8", ".ts");
          status.setText("Probando formato .ts…");
          start();
        } else {
          status.setText("VLC no pudo reproducir este contenido.");
          showBar(true);
        }
        break;
      case MediaPlayer.Event.EndReached:
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(key()).apply();
        if (qIdx + 1 < qUrls.length) playNext(); else finish();
        break;
      default: break;
    }
  }

  private String key() { return "v" + url.hashCode(); }

  private void saveResume() {
    try {
      if (mp == null || length <= 0) return;
      long t = mp.getTime();
      getSharedPreferences(PREFS, MODE_PRIVATE).edit()
          .putLong(key(), t > length - 15000 ? 0 : t).apply();
    } catch (Exception ex) { /* ignorar */ }
  }

  private void playNext() {
    if (qIdx + 1 >= qUrls.length) return;
    saveResume();
    qIdx++;
    url = qUrls[qIdx];
    retried = false; resumed = false; length = 0;
    if (qIdx < qTitles.length) ttl.setText(qTitles[qIdx]);
    bNext.setVisibility(qIdx + 1 < qUrls.length ? View.VISIBLE : View.GONE);
    start();
  }

  private void playPrev() {
    if (qIdx <= 0) return;
    saveResume();
    qIdx--;
    url = qUrls[qIdx];
    retried = false; resumed = false; length = 0;
    if (qIdx < qTitles.length) ttl.setText(qTitles[qIdx]);
    bNext.setVisibility(View.VISIBLE);
    start();
  }

  private boolean isLiveNow() {
    return (url != null && url.contains("/live/")) || (length <= 0 && mp != null && mp.isPlaying());
  }

  private void seekBy(long d) {
    if (mp == null || length <= 0) return;
    long p = Math.max(0, Math.min(length, mp.getTime() + d));
    mp.setTime(p);
    updateProgress();
  }

  private void togglePause() {
    if (mp == null) return;
    if (mp.isPlaying()) mp.pause(); else mp.play();
  }

  private static String fmt(long ms) {
    long s = Math.max(0, ms / 1000);
    return s >= 3600 ? String.format(Locale.US, "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                     : String.format(Locale.US, "%d:%02d", s / 60, s % 60);
  }

  private void updateProgress() {
    if (mp == null || !barOn) return;
    if (length > 0) {
      seek.setVisibility(View.VISIBLE);
      seek.setMax((int) Math.min(Integer.MAX_VALUE, length));
      if (!userSeek) seek.setProgress((int) Math.min(Integer.MAX_VALUE, mp.getTime()));
      tTime.setText(fmt(mp.getTime()) + " / " + fmt(length));
    } else {
      seek.setVisibility(View.INVISIBLE);
      tTime.setText("EN VIVO");
    }
  }

  private void showBar(boolean on) {
    barOn = on;
    bar.setVisibility(on ? View.VISIBLE : View.GONE);
    ttl.setVisibility(on ? View.VISIBLE : View.GONE);
    h.removeCallbacks(hideBar);
    if (on) { updateProgress(); armHide(); }
  }

  private void armHide() {
    h.removeCallbacks(hideBar);
    h.postDelayed(hideBar, 5000);
  }

  private void menu(String title, String[] items, android.content.DialogInterface.OnClickListener l) {
    h.removeCallbacks(hideBar);
    new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
        .setTitle(title).setItems(items, l).show();
  }

  private void pickAudio() {
    final MediaPlayer.TrackDescription[] a = mp.getAudioTracks();
    if (a == null || a.length == 0) { status.setText("Sin pistas de audio"); return; }
    String[] n = new String[a.length];
    for (int i = 0; i < a.length; i++) n[i] = a[i].name;
    menu("Audio", n, (d, w) -> mp.setAudioTrack(a[w].id));
  }

  private void pickSubs() {
    final MediaPlayer.TrackDescription[] s = mp.getSpuTracks();
    if (s == null || s.length == 0) { status.setText("Sin subtítulos"); return; }
    String[] n = new String[s.length];
    for (int i = 0; i < s.length; i++) n[i] = s[i].name;
    menu("Subtítulos", n, (d, w) -> mp.setSpuTrack(s[w].id));
  }

  private void pickAspect() {
    menu("Aspecto", SCN, (d, w) -> { aspect = w; mp.setVideoScale(SC[w]); });
  }

  private void pickRate() {
    String[] n = new String[RATES.length];
    for (int i = 0; i < RATES.length; i++) n[i] = RATES[i] + "x";
    menu("Velocidad", n, (d, w) -> { rateIdx = w; mp.setRate(RATES[w]); });
  }

  @Override
  public boolean dispatchKeyEvent(KeyEvent e) {
    if (e.getAction() == KeyEvent.ACTION_DOWN) {
      int k = e.getKeyCode();
      if (k == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE || k == KeyEvent.KEYCODE_MEDIA_PLAY || k == KeyEvent.KEYCODE_MEDIA_PAUSE) { togglePause(); showBar(true); return true; }
      if (k == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD) { seekBy(skipMs * 3L); return true; }
      if (k == KeyEvent.KEYCODE_MEDIA_REWIND) { seekBy(-skipMs * 3L); return true; }
      if (k == KeyEvent.KEYCODE_MEDIA_NEXT || k == KeyEvent.KEYCODE_CHANNEL_UP) { playNext(); return true; }
      if (k == KeyEvent.KEYCODE_MEDIA_PREVIOUS || k == KeyEvent.KEYCODE_CHANNEL_DOWN) { playPrev(); return true; }
      if (isLiveNow()) {
        /* TV en vivo: ▲ canal siguiente, ▼ canal anterior, ◀ ▶ abren las opciones */
        if (k == KeyEvent.KEYCODE_DPAD_UP) { playNext(); showBar(true); return true; }
        if (k == KeyEvent.KEYCODE_DPAD_DOWN) { playPrev(); showBar(true); return true; }
        if (!barOn && (k == KeyEvent.KEYCODE_DPAD_LEFT || k == KeyEvent.KEYCODE_DPAD_RIGHT)) {
          showBar(true);
          if (bar.getChildCount() > 1) bar.getChildAt(1).requestFocus();
          return true;
        }
      }
      if (!barOn) {
        if (k == KeyEvent.KEYCODE_DPAD_LEFT) { seekBy(-skipMs); return true; }
        if (k == KeyEvent.KEYCODE_DPAD_RIGHT) { seekBy(skipMs); return true; }
        if (k == KeyEvent.KEYCODE_DPAD_CENTER || k == KeyEvent.KEYCODE_ENTER) { togglePause(); showBar(true); return true; }
        if (k == KeyEvent.KEYCODE_DPAD_UP || k == KeyEvent.KEYCODE_DPAD_DOWN) {
          showBar(true);
          if (bar.getChildCount() > 1) bar.getChildAt(1).requestFocus();
          return true;
        }
      } else {
        armHide();
        if (k == KeyEvent.KEYCODE_BACK) { showBar(false); return true; }
      }
    }
    return super.dispatchKeyEvent(e);
  }

  @Override
  protected void onStop() {
    super.onStop();
    saveResume();
    if (mp != null) mp.pause();
  }

  @Override
  protected void onDestroy() {
    h.removeCallbacksAndMessages(null);
    saveResume();
    try {
      if (mp != null) { mp.setEventListener(null); mp.stop(); mp.detachViews(); mp.release(); }
      if (libVLC != null) libVLC.release();
    } catch (Exception ex) { /* ignorar */ }
    super.onDestroy();
  }
}
JAVA

cat > $PKG/PlayerActivity.java <<'JAVA'
package com.glystv.app;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.Tracks;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;

public class PlayerActivity extends Activity {
  private ExoPlayer player;
  private TextView status;
  private String url;
  private boolean retried = false;
  private String firstInfo = "";
  private final Runnable clear = () -> status.setText("");

  private static final int GOLD = Color.rgb(140, 198, 63);
  private long t0 = 0;
  private String retryInfo = "";
  private int nRetries = 0;
  private static final String PREFS = "glystv_resume";
  private String resumeKey = "";
  private String resumeNote = "";
  private TextView ttlView;
  private PlayerView pvRef;
  private TextView nextBtn;
  private String[] qUrls = new String[0];
  private String[] qTitles = new String[0];
  private int qIdx = 0;
  private int skipMs = 10000;
  private final android.os.Handler uiH = new android.os.Handler(android.os.Looper.getMainLooper());
  private Runnable sleepR;

  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);

    getWindow().addFlags(
        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

    getWindow().getDecorView().setSystemUiVisibility(
        View.SYSTEM_UI_FLAG_FULLSCREEN |
        View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
        View.SYSTEM_UI_FLAG_LAYOUT_STABLE);

    url = getIntent().getStringExtra("url");
    resumeKey = "p" + (url == null ? 0 : url.hashCode());
    String title = getIntent().getStringExtra("title");

    FrameLayout root = new FrameLayout(this);
    root.setBackgroundColor(Color.BLACK);

    PlayerView pv = new PlayerView(this);
    pv.setUseController(true);
    pv.setControllerShowTimeoutMs(3500);
    pv.setControllerHideOnTouch(true);
    pv.setControllerAutoShow(true);
    pv.setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING);
    /* Centro limpio: solo play/pausa (se quitan anterior, atrás, adelante y siguiente) */
    pv.setShowPreviousButton(false);
    pv.setShowNextButton(false);
    pv.setShowRewindButton(false);
    pv.setShowFastForwardButton(false);

    root.addView(pv,
        new FrameLayout.LayoutParams(-1, -1));

    status = new TextView(this);
    status.setTextColor(Color.WHITE);
    status.setTextSize(14);
    try {
      status.setTypeface(android.graphics.Typeface.createFromAsset(
          getAssets(), "fonts/open_sans.ttf"));
    } catch (Exception e) { /* si falta la fuente, usa la del sistema */ }
    status.setPadding(32, 24, 32, 24);
    status.setShadowLayer(5, 2, 2, Color.BLACK);
    status.setText("");

    final TextView ttl = new TextView(this);
    ttlView = ttl;
    parseQueue();
    ttl.setTextColor(Color.WHITE);
    ttl.setTextSize(20);
    ttl.setSingleLine(true);
    ttl.setEllipsize(android.text.TextUtils.TruncateAt.END);
    try {
      ttl.setTypeface(android.graphics.Typeface.createFromAsset(
          getAssets(), "fonts/open_sans.ttf"));
    } catch (Exception e) { /* si falta la fuente, usa la del sistema */ }
    ttl.setShadowLayer(6, 2, 2, Color.BLACK);
    ttl.setPadding(32, 24, 32, 12);
    ttl.setText(title == null ? "" : title);
    root.addView(ttl,
        new FrameLayout.LayoutParams(
            -1, -2, Gravity.TOP | Gravity.START));
    pv.setControllerVisibilityListener((PlayerView.ControllerVisibilityListener) vis ->
        ttl.setVisibility(vis == View.VISIBLE ? View.VISIBLE : View.GONE));

    FrameLayout.LayoutParams stLp =
        new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START);
    stLp.topMargin = 90;
    root.addView(status, stLp);

    setContentView(root);

    pv.post(() -> {
      applyCinemaStyle(pv);
      addZoomButton(pv, root);
      pvRef = pv;
      addExtraButtons(pv, root);
    });

    DefaultHttpDataSource.Factory http =
        new DefaultHttpDataSource.Factory()
            .setUserAgent("Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(8000)
            .setReadTimeoutMs(8000);

    DefaultRenderersFactory rf =
        new DefaultRenderersFactory(this)
            .setEnableDecoderFallback(true)   /* si el decodificador por hardware falla, prueba otro (HEVC/VP9/AV1…) */
            .setExtensionRendererMode(
                DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER);

    /* Búfer según Opciones → Buffer (Rápido / Normal / Estable).
       Normal = comportamiento anterior (arranque con 0,5 s de vídeo). Estable limita a 64 MB para no agotar la memoria de la TV box. */
    int bufProfile = bufferProfile();
    int[] bd;
    switch (bufProfile) {
      case 0:  bd = new int[]{15000, 30000, 500, 1500};   break; /* Rápido */
      case 2:  bd = new int[]{50000, 120000, 3000, 6000}; break; /* Estable */
      default: bd = new int[]{15000, 50000, 500, 2000};   break; /* Normal */
    }
    androidx.media3.exoplayer.DefaultLoadControl.Builder lcb =
        new androidx.media3.exoplayer.DefaultLoadControl.Builder()
            .setBufferDurationsMs(bd[0], bd[1], bd[2], bd[3]);
    if (bufProfile == 2) {
      lcb.setTargetBufferBytes(64 * 1024 * 1024).setPrioritizeTimeOverSizeThresholds(false);
    }
    androidx.media3.exoplayer.DefaultLoadControl lc = lcb.build();

    player = new ExoPlayer.Builder(this, rf)
        .setLoadControl(lc)
        .setMediaSourceFactory(
            new DefaultMediaSourceFactory(this)
                .setDataSourceFactory(http))
        .build();

    pv.setPlayer(player);

    player.addListener(new Player.Listener() {

      @Override
      public void onPlayerError(PlaybackException e) {
        String info = describe(e);

        if (!retried && url.contains(".m3u8")) {
          retried = true;
          firstInfo = info;
          url = url.replace(".m3u8", ".ts");
          status.setText("Cargando…");
          start();
        } else if (!"exo".equals(getIntent().getStringExtra("engine"))) {
          launchVlc();
        } else {
          status.setText("No se pudo cargar este contenido.");
        }
      }

      @Override
      public void onPlaybackStateChanged(int st) {
        if (st == Player.STATE_ENDED && qIdx + 1 < qUrls.length) playNext();
      }

      @Override
      public void onRenderedFirstFrame() {
        long sec10 = (android.os.SystemClock.elapsedRealtime() - t0) / 100;
        status.setText("");
        status.removeCallbacks(clear);
      }

      @Override
      public void onTracksChanged(Tracks tracks) {
        if (tracks.getGroups().isEmpty()) return;

        StringBuilder sb = new StringBuilder();

        for (Tracks.Group g : tracks.getGroups()) {
          if (g.getType() == C.TRACK_TYPE_AUDIO) {
            for (int i = 0; i < g.length; i++) {
              sb.append(g.getTrackFormat(i).sampleMimeType)
                .append(g.isTrackSupported(i)
                    ? " ok " : " SIN-SOPORTE ");
            }
          }
        }

        /* sin texto técnico de audio en pantalla */
      }
    });

    player.addAnalyticsListener(new androidx.media3.exoplayer.analytics.AnalyticsListener() {
      @Override
      public void onLoadError(
          androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime eventTime,
          androidx.media3.exoplayer.source.LoadEventInfo loadEventInfo,
          androidx.media3.exoplayer.source.MediaLoadData mediaLoadData,
          java.io.IOException error,
          boolean wasCanceled) {
        long sec = (android.os.SystemClock.elapsedRealtime() - t0) / 1000;
        Throwable why = error.getCause() != null ? error.getCause() : error;
        String msg = why.getClass().getSimpleName() + ": " + String.valueOf(why.getMessage());
        if (msg.length() > 90) msg = msg.substring(0, 90);
        nRetries++;
        /* reintenta en silencio: no se muestra el error técnico sobre el vídeo */
      }
    });

    start();
  }

  private int aspectMode = 0;
  private static final String[] ASP = {"Normal", "Zoom", "Estirar"};

  /* Botón Zoom junto al engranaje de ajustes: Normal / Zoom / Estirar */
  private void addZoomButton(PlayerView pv, FrameLayout root) {
    final TextView z = new TextView(this);
    z.setText("▣ Normal");
    z.setTextColor(GOLD);
    z.setTextSize(14);
    z.setGravity(Gravity.CENTER);
    z.setPadding(24, 12, 24, 12);
    z.setFocusable(true);
    z.setClickable(true);
    z.setOnFocusChangeListener((view, f) ->
        z.setBackgroundColor(f ? Color.argb(120, 140, 198, 63) : Color.TRANSPARENT));
    z.setOnClickListener(view -> {
      aspectMode = (aspectMode + 1) % ASP.length;
      pv.setResizeMode(aspectMode == 1 ? AspectRatioFrameLayout.RESIZE_MODE_ZOOM
          : aspectMode == 2 ? AspectRatioFrameLayout.RESIZE_MODE_FILL
          : AspectRatioFrameLayout.RESIZE_MODE_FIT);
      z.setText("▣ " + ASP[aspectMode]);
    });
    int sid = getResources().getIdentifier("exo_settings", "id", getPackageName());
    View st = sid == 0 ? null : pv.findViewById(sid);
    if (st != null && st.getParent() instanceof android.widget.LinearLayout) {
      android.widget.LinearLayout p = (android.widget.LinearLayout) st.getParent();
      p.addView(z, p.indexOfChild(st));
    } else {
      root.addView(z, new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END));
    }
  }

  private void applyCinemaStyle(PlayerView pv) {
    String[] buttons = {
        "exo_play_pause",
        "exo_play",
        "exo_pause",
        "exo_prev",
        "exo_next",
        "exo_rew",
        "exo_ffwd",
        "exo_repeat_toggle",
        "exo_shuffle",
        "exo_settings",
        "exo_subtitle",
        "exo_audio_track"
    };

    for (String name : buttons) {
      int id = getResources().getIdentifier(
          name, "id", getPackageName());

      if (id != 0) {
        View button = pv.findViewById(id);

        if (button instanceof android.widget.ImageView) {
          ((android.widget.ImageView) button).setColorFilter(
              GOLD,
              android.graphics.PorterDuff.Mode.SRC_IN);
        }
      }
    }

    /* Play/pausa del centro: sin cuadro (verde/amarillo) de enfoque alrededor */
    for (String name : new String[]{"exo_play_pause", "exo_play", "exo_pause"}) {
      int pid = getResources().getIdentifier(name, "id", getPackageName());
      View pb = pid == 0 ? null : pv.findViewById(pid);
      if (pb != null) noFocusBox(pb);
    }

    try {
      android.graphics.Typeface tf = android.graphics.Typeface.createFromAsset(
          getAssets(), "fonts/open_sans.ttf");
      for (String name : new String[]{"exo_position", "exo_duration"}) {
        int tid = getResources().getIdentifier(name, "id", getPackageName());
        View tv = tid == 0 ? null : pv.findViewById(tid);
        if (tv instanceof TextView) ((TextView) tv).setTypeface(tf);
      }
    } catch (Exception e) { /* opcional */ }

    int progressId = getResources().getIdentifier(
        "exo_progress", "id", getPackageName());

    if (progressId != 0) {
      View progress = pv.findViewById(progressId);

      if (progress instanceof androidx.media3.ui.DefaultTimeBar) {
        androidx.media3.ui.DefaultTimeBar bar =
            (androidx.media3.ui.DefaultTimeBar) progress;

        bar.setPlayedColor(GOLD);
        bar.setScrubberColor(GOLD);
        bar.setBufferedColor(Color.GRAY);
        bar.setUnplayedColor(Color.DKGRAY);
      }
    }
  }

  private void noFocusBox(View v) {
    try {
      if (android.os.Build.VERSION.SDK_INT >= 26) v.setDefaultFocusHighlightEnabled(false);
      if (android.os.Build.VERSION.SDK_INT >= 23) v.setForeground(null);
      v.setBackground(null);
    } catch (Throwable t) { /* opcional */ }
  }

  /* Atrasar/adelantar con las flechas del control (skipMs) */
  private void seekRel(int dir) {
    if (player == null) return;
    long d = player.getDuration();
    long p = player.getCurrentPosition() + dir * (long) skipMs;
    if (p < 0) p = 0;
    if (d != C.TIME_UNSET && p > d) p = d;
    player.seekTo(p);
  }

  private boolean focusOnPlayPauseOrNone() {
    View f = getCurrentFocus();
    if (f == null) return true;
    int id = getResources().getIdentifier("exo_play_pause", "id", getPackageName());
    return id != 0 && f.getId() == id;
  }

  /* Si ExoPlayer no puede, se abre el mismo contenido con VLC */
  private void launchVlc() {
    android.content.Intent i = new android.content.Intent(this, VlcPlayerActivity.class);
    i.putExtras(getIntent());
    i.putExtra("engine", "vlc");
    if (qUrls.length > 0 && qIdx < qUrls.length) {
      i.putExtra("url", qUrls[qIdx]);
      i.putExtra("idx", qIdx);
    } else {
      i.putExtra("url", getIntent().getStringExtra("url"));
    }
    startActivity(i);
    finish();
  }

  private void parseQueue() {
    String u = getIntent().getStringExtra("urls");
    String t = getIntent().getStringExtra("titles");
    if (u != null && !u.isEmpty()) {
      qUrls = u.split("\n");
      qTitles = t == null ? new String[0] : t.split("\n");
      qIdx = getIntent().getIntExtra("idx", 0);
    }
    skipMs = getSharedPreferences("glystv_prefs", MODE_PRIVATE).getInt("skip", 10000);
  }

  private TextView mkBtn(String txt) {
    final TextView b = new TextView(this);
    b.setText(txt);
    b.setTextColor(GOLD);
    b.setTextSize(14);
    b.setGravity(Gravity.CENTER);
    b.setPadding(24, 12, 24, 12);
    b.setFocusable(true);
    b.setClickable(true);
    b.setOnFocusChangeListener((view, f) ->
        b.setBackgroundColor(f ? Color.argb(120, 140, 198, 63) : Color.TRANSPARENT));
    return b;
  }

  private void addExtraButtons(PlayerView pv, FrameLayout root) {
    TextView more = mkBtn("Más");
    more.setOnClickListener(x -> showMenu());
    nextBtn = mkBtn("Siguiente ›");
    nextBtn.setOnClickListener(x -> playNext());
    nextBtn.setVisibility(qIdx + 1 < qUrls.length ? View.VISIBLE : View.GONE);
    int sid = getResources().getIdentifier("exo_settings", "id", getPackageName());
    View st = sid == 0 ? null : pv.findViewById(sid);
    if (st != null && st.getParent() instanceof android.widget.LinearLayout) {
      android.widget.LinearLayout p = (android.widget.LinearLayout) st.getParent();
      int at = p.indexOfChild(st);
      p.addView(nextBtn, at);
      p.addView(more, at);
    } else {
      root.addView(more, new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END));
    }
    bindSkip("exo_rew", -1);
    bindSkip("exo_ffwd", 1);
  }

  private void bindSkip(String name, final int dir) {
    int id = getResources().getIdentifier(name, "id", getPackageName());
    View b = id == 0 ? null : pvRef.findViewById(id);
    if (b == null) return;
    b.setOnClickListener(x -> {
      long d = player.getDuration();
      long p = player.getCurrentPosition() + dir * (long) skipMs;
      if (p < 0) p = 0;
      if (d != C.TIME_UNSET && p > d) p = d;
      player.seekTo(p);
    });
  }

  private void playNext() {
    if (qIdx + 1 >= qUrls.length) return;
    saveResume();
    qIdx++;
    url = qUrls[qIdx];
    resumeKey = "p" + url.hashCode();
    retried = false; firstInfo = ""; resumeNote = ""; retryInfo = ""; nRetries = 0;
    if (ttlView != null && qIdx < qTitles.length) ttlView.setText(qTitles[qIdx]);
    if (nextBtn != null) nextBtn.setVisibility(qIdx + 1 < qUrls.length ? View.VISIBLE : View.GONE);
    start();
  }

  private void playPrev() {
    if (qIdx <= 0) return;
    saveResume();
    qIdx--;
    url = qUrls[qIdx];
    resumeKey = "p" + url.hashCode();
    retried = false; firstInfo = ""; resumeNote = ""; retryInfo = ""; nRetries = 0;
    if (ttlView != null && qIdx < qTitles.length) ttlView.setText(qTitles[qIdx]);
    if (nextBtn != null) nextBtn.setVisibility(View.VISIBLE);
    start();
  }

  /* TV en vivo: ▲ canal siguiente, ▼ canal anterior, ◀ ▶ muestran los controles */
  @Override
  public boolean dispatchKeyEvent(android.view.KeyEvent e) {
    if (e.getAction() == android.view.KeyEvent.ACTION_DOWN && url != null && url.contains("/live/")) {
      int k = e.getKeyCode();
      if (k == android.view.KeyEvent.KEYCODE_DPAD_UP) { playNext(); if (pvRef != null) pvRef.showController(); return true; }
      if (k == android.view.KeyEvent.KEYCODE_DPAD_DOWN) { playPrev(); if (pvRef != null) pvRef.showController(); return true; }
      if ((k == android.view.KeyEvent.KEYCODE_DPAD_LEFT || k == android.view.KeyEvent.KEYCODE_DPAD_RIGHT)
          && pvRef != null && !pvRef.isControllerFullyVisible()) { pvRef.showController(); return true; }
    }
    if (e.getAction() == android.view.KeyEvent.ACTION_DOWN && url != null && !url.contains("/live/")
        && pvRef != null && player != null) {
      int k2 = e.getKeyCode();
      if (k2 == android.view.KeyEvent.KEYCODE_DPAD_LEFT || k2 == android.view.KeyEvent.KEYCODE_DPAD_RIGHT) {
        if (!pvRef.isControllerFullyVisible() || focusOnPlayPauseOrNone()) {
          seekRel(k2 == android.view.KeyEvent.KEYCODE_DPAD_RIGHT ? 1 : -1);
          pvRef.showController();
          return true;
        }
      }
    }
    return super.dispatchKeyEvent(e);
  }

  /* Menú lateral oscuro/azul (reemplaza el cuadro blanco centrado) */
  private class SideMenu {
    private final android.content.Context c;
    private String title = "";
    private String[] items = new String[0];
    private android.content.DialogInterface.OnClickListener l;
    SideMenu(android.content.Context c) { this.c = c; }
    SideMenu setTitle(String t) { title = t; return this; }
    SideMenu setItems(String[] it, android.content.DialogInterface.OnClickListener l) { items = it; this.l = l; return this; }
    void show() {
      final android.app.Dialog dlg = new android.app.Dialog(c);
      dlg.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
      float dn = getResources().getDisplayMetrics().density;
      android.widget.LinearLayout col = new android.widget.LinearLayout(c);
      col.setOrientation(android.widget.LinearLayout.VERTICAL);
      col.setBackgroundColor(Color.rgb(10, 18, 8));
      TextView h = new TextView(c);
      h.setText(title.toUpperCase());
      h.setTextColor(GOLD);
      h.setTextSize(15);
      h.setPadding((int) (20 * dn), (int) (18 * dn), (int) (20 * dn), (int) (12 * dn));
      col.addView(h);
      View line = new View(c);
      line.setBackgroundColor(Color.rgb(140, 198, 63));
      col.addView(line, new android.widget.LinearLayout.LayoutParams(-1, (int) (2 * dn)));
      android.widget.LinearLayout box = new android.widget.LinearLayout(c);
      box.setOrientation(android.widget.LinearLayout.VERTICAL);
      android.widget.ScrollView sv = new android.widget.ScrollView(c);
      sv.addView(box);
      col.addView(sv, new android.widget.LinearLayout.LayoutParams(-1, -1));
      TextView first = null;
      for (int i = 0; i < items.length; i++) {
        final int w = i;
        final TextView t = new TextView(c);
        t.setText(items[i]);
        t.setTextColor(Color.WHITE);
        t.setTextSize(17);
        t.setPadding((int) (20 * dn), (int) (15 * dn), (int) (20 * dn), (int) (15 * dn));
        t.setFocusable(true);
        t.setClickable(true);
        t.setOnFocusChangeListener((view, f) ->
            t.setBackgroundColor(f ? Color.rgb(140, 198, 63) : Color.TRANSPARENT));
        t.setOnClickListener(view -> { dlg.dismiss(); if (l != null) l.onClick(dlg, w); });
        box.addView(t);
        if (first == null) first = t;
      }
      dlg.setContentView(col);
      android.view.Window win = dlg.getWindow();
      if (win != null) {
        win.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        win.setGravity(Gravity.END | Gravity.TOP);
        win.setLayout((int) (320 * dn), WindowManager.LayoutParams.MATCH_PARENT);
        win.setDimAmount(0.35f);
        win.getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
      }
      dlg.show();
      if (first != null) first.requestFocus();
    }
  }

  private void showMenu() {
    java.util.ArrayList<String> it = new java.util.ArrayList<>();
    it.add("Audio");
    it.add("Subtítulos");
    it.add("Velocidad");
    it.add("Temporizador para dormir");
    it.add("Salto: " + (skipMs / 1000) + " s");
    it.add("Buffer: " + BUF_NAMES[bufferProfile()]);
    if (url != null && url.contains("/live/")) it.add("Formato de respaldo");
    new SideMenu(this)
        .setTitle("Opciones")
        .setItems(it.toArray(new String[0]), (d, w) -> {
          if (w == 0) pickTrack(C.TRACK_TYPE_AUDIO);
          else if (w == 1) pickTrack(C.TRACK_TYPE_TEXT);
          else if (w == 2) pickSpeed();
          else if (w == 3) pickSleep();
          else if (w == 4) pickSkip();
          else if (w == 5) pickBuffer();
          else pickFormat();
        }).show();
  }

  /* Perfiles de búfer (se guardan y se aplican en la siguiente reproducción) */
  private static final String[] BUF_NAMES = {"Rápido", "Normal", "Estable"};

  private int bufferProfile() {
    int b = getSharedPreferences("glystv_prefs", MODE_PRIVATE).getInt("buffer", 1);
    return (b < 0 || b > 2) ? 1 : b;
  }

  private void pickBuffer() {
    new SideMenu(this).setTitle("Buffer")
        .setItems(new String[]{
            "Rápido · menos retraso en TV en vivo",
            "Normal · uso general",
            "Estable · internet lenta o 4K"}, (d, w) -> {
          getSharedPreferences("glystv_prefs", MODE_PRIVATE).edit().putInt("buffer", w).apply();
          say("Buffer: " + BUF_NAMES[w] + " · se aplica en la próxima reproducción");
        }).show();
  }

  private void say(String m) { status.setText(m); status.removeCallbacks(clear); status.postDelayed(clear, 4000); }

  private void pickTrack(final int type) {
    final java.util.ArrayList<String> names = new java.util.ArrayList<>();
    final java.util.ArrayList<Tracks.Group> gs = new java.util.ArrayList<>();
    final java.util.ArrayList<Integer> idx = new java.util.ArrayList<>();
    if (type == C.TRACK_TYPE_TEXT) { names.add("Desactivados"); gs.add(null); idx.add(-1); }
    for (Tracks.Group g : player.getCurrentTracks().getGroups()) {
      if (g.getType() != type) continue;
      for (int i = 0; i < g.length; i++) {
        androidx.media3.common.Format f = g.getTrackFormat(i);
        String n = f.label != null ? f.label
            : (f.language != null ? new java.util.Locale(f.language).getDisplayLanguage()
            : "Pista " + (names.size() + 1));
        names.add(n); gs.add(g); idx.add(i);
      }
    }
    if (names.isEmpty() || (type == C.TRACK_TYPE_TEXT && names.size() == 1)) {
      say(type == C.TRACK_TYPE_TEXT ? "Sin subtítulos disponibles" : "Sin pistas de audio alternas");
      return;
    }
    new SideMenu(this)
        .setTitle(type == C.TRACK_TYPE_TEXT ? "Subtítulos" : "Audio")
        .setItems(names.toArray(new String[0]), (d, w) -> {
          androidx.media3.common.TrackSelectionParameters.Builder b =
              player.getTrackSelectionParameters().buildUpon();
          if (gs.get(w) == null) {
            b.setTrackTypeDisabled(type, true);
          } else {
            b.setTrackTypeDisabled(type, false);
            b.setOverrideForType(new androidx.media3.common.TrackSelectionOverride(
                gs.get(w).getMediaTrackGroup(), idx.get(w)));
          }
          player.setTrackSelectionParameters(b.build());
        }).show();
  }

  private void pickSpeed() {
    final float[] v = {0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f};
    new SideMenu(this).setTitle("Velocidad")
        .setItems(new String[]{"0.5x", "0.75x", "Normal", "1.25x", "1.5x", "2x"}, (d, w) ->
            player.setPlaybackParameters(new androidx.media3.common.PlaybackParameters(v[w])))
        .show();
  }

  private void pickSleep() {
    final int[] mins = {0, 15, 30, 45, 60, 90};
    new SideMenu(this).setTitle("Temporizador para dormir")
        .setItems(new String[]{"Desactivado", "15 minutos", "30 minutos", "45 minutos", "60 minutos", "90 minutos"}, (d, w) -> {
          if (sleepR != null) uiH.removeCallbacks(sleepR);
          sleepR = null;
          if (mins[w] > 0) {
            sleepR = () -> { player.pause(); say("Temporizador: reproducción detenida"); };
            uiH.postDelayed(sleepR, mins[w] * 60000L);
            say("Se detendrá en " + mins[w] + " min");
          }
        }).show();
  }

  private void pickSkip() {
    final int[] secs = {10, 30, 60};
    new SideMenu(this).setTitle("Salto de retroceso/avance")
        .setItems(new String[]{"10 segundos", "30 segundos", "60 segundos"}, (d, w) -> {
          skipMs = secs[w] * 1000;
          getSharedPreferences("glystv_prefs", MODE_PRIVATE).edit().putInt("skip", skipMs).apply();
        }).show();
  }

  private void pickFormat() {
    final String[] ex = {"m3u8", "ts", "mp4"};
    new SideMenu(this).setTitle("Formato de respaldo")
        .setItems(new String[]{"M3U8 (HLS)", "TS", "MP4"}, (d, w) -> {
          url = url.replaceAll("\\.(m3u8|ts|mp4|mkv)$", "." + ex[w]);
          retried = true;
          say("Probando " + ex[w].toUpperCase() + "…");
          start();
        }).show();
  }

  @Override
  protected void onStop() {
    if (sleepR != null) uiH.removeCallbacks(sleepR);
    super.onStop();
  }


  private String describe(PlaybackException e) {
    Throwable c = e.getCause();

    if (c instanceof HttpDataSource.InvalidResponseCodeException) {
      return "HTTP " +
          ((HttpDataSource.InvalidResponseCodeException) c).responseCode;
    }

    return e.getErrorCodeName();
  }

  private void start() {
    t0 = android.os.SystemClock.elapsedRealtime();
    long saved = 0;
    if (!retried) saved = getSharedPreferences(PREFS, MODE_PRIVATE).getLong(resumeKey, 0);
    MediaItem item = MediaItem.fromUri(url);
    if (saved > 0) {
      player.setMediaItem(item, saved);
      resumeNote = "\nRetomando desde " + fmt(saved);
    } else {
      player.setMediaItem(item);
    }
    player.prepare();
    player.play();
  }

  private String fmt(long ms) {
    long sec = ms / 1000;
    return String.format(java.util.Locale.US, "%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60);
  }

  /* Continuar viendo: solo películas/series (duración > 10 min, no en vivo) */
  private void saveResume() {
    try {
      if (player == null) return;
      long dur = player.getDuration();
      long pos = player.getCurrentPosition();
      if (dur == C.TIME_UNSET || dur < 600000 || player.isCurrentMediaItemLive()) return;
      android.content.SharedPreferences.Editor ed =
          getSharedPreferences(PREFS, MODE_PRIVATE).edit();
      if (pos > 30000 && pos < dur - 60000) ed.putLong(resumeKey, pos);
      else ed.remove(resumeKey);
      ed.apply();
    } catch (Exception e) { /* opcional */ }
  }

  @Override
  protected void onPause() {
    saveResume();
    super.onPause();
  }

  @Override
  protected void onDestroy() {
    saveResume();
    if (player != null) player.release();
    super.onDestroy();
  }
}
JAVA

mkdir -p android/app/src/main/assets
mkdir -p android/app/src/main/assets/fonts
cp fonts/*.ttf android/app/src/main/assets/fonts/ 2>/dev/null || true
cat > $PKG/RemoteSetupPlugin.java <<'RSJAVA'
package com.glystv.app;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

@CapacitorPlugin(name = "RemoteSetup")
public class RemoteSetupPlugin extends Plugin {
  private ServerSocket server;
  private String token = "";
  private String prefill = "";
  private int port = 0;

  @PluginMethod
  public synchronized void start(PluginCall call) {
    String s = call.getString("s", "");
    prefill = s == null ? "" : s;
    try {
      if (server == null || server.isClosed()) {
        token = String.valueOf(100000 + new SecureRandom().nextInt(900000));
        server = null;
        for (int p = 8765; p < 8785 && server == null; p++) {
          try { server = new ServerSocket(p); port = p; } catch (Exception e) { }
        }
        if (server == null) { call.reject("Sin puerto libre"); return; }
        final ServerSocket ss = server;
        Thread t = new Thread(() -> loop(ss));
        t.setDaemon(true);
        t.start();
      }
      String ip = localIp();
      if (ip == null) { call.reject("Sin red local Wi-Fi o Ethernet"); return; }
      JSObject o = new JSObject();
      o.put("url", "http://" + ip + ":" + port + "/?k=" + token);
      call.resolve(o);
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }

  @PluginMethod
  public void stop(PluginCall call) {
    closeServer();
    call.resolve();
  }

  @Override
  protected void handleOnDestroy() {
    closeServer();
  }

  private synchronized void closeServer() {
    try { if (server != null) server.close(); } catch (Exception e) { }
    server = null;
  }

  private void loop(ServerSocket ss) {
    while (!ss.isClosed()) {
      try {
        Socket c = ss.accept();
        c.setSoTimeout(5000);
        handle(c);
      } catch (Exception e) {
        if (ss.isClosed()) break;
      }
    }
  }

  private void handle(Socket c) {
    try {
      InputStream in = c.getInputStream();
      OutputStream out = c.getOutputStream();
      String req = readLine(in);
      if (req == null) return;
      int len = 0;
      String line;
      while ((line = readLine(in)) != null && line.length() > 0) {
        if (line.toLowerCase(Locale.ROOT).startsWith("content-length:")) {
          len = Integer.parseInt(line.substring(15).trim());
        }
      }
      String[] parts = req.split(" ");
      String method = parts[0];
      String target = parts.length > 1 ? parts[1] : "/";
      String path = target, query = "";
      int q = target.indexOf('?');
      if (q >= 0) { path = target.substring(0, q); query = target.substring(q + 1); }
      Map<String, String> qs = form(query);
      if (!token.equals(qs.get("k"))) {
        reply(out, 403, "text/plain; charset=utf-8", "Codigo invalido. Escanea de nuevo el QR de la TV.");
        return;
      }
      if (method.equals("POST") && path.equals("/send")) {
        if (len > 4096) { reply(out, 413, "text/plain; charset=utf-8", "Muy grande"); return; }
        byte[] body = new byte[len];
        int got = 0;
        while (got < len) {
          int r = in.read(body, got, len - got);
          if (r < 0) break;
          got += r;
        }
        Map<String, String> f = form(new String(body, 0, got, StandardCharsets.UTF_8));
        JSObject o = new JSObject();
        o.put("s", f.containsKey("s") ? f.get("s") : "");
        o.put("u", f.containsKey("u") ? f.get("u") : "");
        o.put("p", f.containsKey("p") ? f.get("p") : "");
        notifyListeners("remote", o);
        reply(out, 200, "text/plain; charset=utf-8", "OK");
      } else {
        reply(out, 200, "text/html; charset=utf-8", page());
      }
    } catch (Exception e) {
    } finally {
      try { c.close(); } catch (Exception e) { }
    }
  }

  private String page() throws Exception {
    InputStream is = getContext().getAssets().open("remote.html");
    ByteArrayOutputStream bo = new ByteArrayOutputStream();
    byte[] buf = new byte[2048];
    int n;
    while ((n = is.read(buf)) > 0) bo.write(buf, 0, n);
    is.close();
    String s = prefill.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    return bo.toString("UTF-8").replace("%%S%%", s);
  }

  private static void reply(OutputStream out, int code, String type, String body) throws Exception {
    byte[] b = body.getBytes(StandardCharsets.UTF_8);
    String h = "HTTP/1.1 " + code + " X\r\nContent-Type: " + type + "\r\nContent-Length: " + b.length
        + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
    out.write(h.getBytes(StandardCharsets.UTF_8));
    out.write(b);
    out.flush();
  }

  private static String readLine(InputStream in) throws Exception {
    StringBuilder sb = new StringBuilder();
    int c;
    while ((c = in.read()) >= 0) {
      if (c == '\n') break;
      if (c != '\r') sb.append((char) c);
      if (sb.length() > 4096) break;
    }
    return (c < 0 && sb.length() == 0) ? null : sb.toString();
  }

  private static Map<String, String> form(String s) {
    Map<String, String> m = new HashMap<>();
    for (String kv : s.split("&")) {
      int i = kv.indexOf('=');
      if (i < 0) continue;
      try {
        m.put(URLDecoder.decode(kv.substring(0, i), "UTF-8"), URLDecoder.decode(kv.substring(i + 1), "UTF-8"));
      } catch (Exception e) { }
    }
    return m;
  }

  private static String localIp() {
    try {
      String fallback = null;
      for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
        if (!ni.isUp() || ni.isLoopback()) continue;
        for (InetAddress a : Collections.list(ni.getInetAddresses())) {
          if (a instanceof Inet4Address && a.isSiteLocalAddress()) {
            String nm = ni.getName();
            if (nm.startsWith("wlan") || nm.startsWith("eth") || nm.startsWith("en") || nm.startsWith("rmnet")) return a.getHostAddress();
            if (fallback == null) fallback = a.getHostAddress();
          }
        }
      }
      return fallback;
    } catch (Exception e) {
      return null;
    }
  }
}
RSJAVA

cat > android/app/src/main/assets/remote.html <<'RSHTML'
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ULTRA4K</title>
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:linear-gradient(160deg,#0a1208,#1d3a0f);font-family:system-ui,sans-serif;color:#fff;padding:16px}
form{width:100%;max-width:420px;background:#0f1014;border:1px solid #343238;border-radius:18px;padding:26px 22px}
h1{margin:0 0 4px;text-align:center;font-size:28px}h1 b{color:#8cc63f}p{margin:0 0 18px;text-align:center;color:#bbb;font-size:15px}
input[type=text],input[type=url],input[type=password]{width:100%;height:52px;margin-bottom:14px;border:1px solid #34343b;border-radius:10px;padding:0 14px;font-size:17px;color:#fff;background:#090a0d}
label{display:block;margin:0 0 16px;font-size:15px;color:#ddd}
button{width:100%;height:52px;border:0;border-radius:10px;background:linear-gradient(110deg,#5e9e2a,#8cc63f);color:#fff;font-size:17px;font-weight:700}
#m{margin-top:14px;text-align:center;font-size:15px;min-height:20px}
</style></head><body>
<form id="f" autocomplete="off"><h1>ULTRA<b>4K</b></h1><p>Escribe tus datos y se enviarán a la TV</p>
<input name="s" type="url" placeholder="URL del servidor (http://...)" value="%%S%%" autocapitalize="off" autocorrect="off" required>
<input name="u" type="text" placeholder="Usuario" autocapitalize="off" autocorrect="off" required>
<input name="p" id="p" type="password" placeholder="Contraseña" autocapitalize="off" required>
<label><input type="checkbox" id="sh"> Mostrar contraseña</label>
<button id="b">ENVIAR A LA TV</button><div id="m"></div></form>
<script>
var f=document.getElementById('f'),m=document.getElementById('m'),b=document.getElementById('b');
document.getElementById('sh').onchange=function(){document.getElementById('p').type=this.checked?'text':'password'};
f.onsubmit=function(e){e.preventDefault();b.disabled=true;m.textContent='Enviando…';
fetch('send'+location.search,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(new FormData(f)).toString()})
.then(function(r){if(!r.ok)throw 0;m.textContent='✔ Enviado. Mira la TV.';m.style.color='#8cc63f'})
.catch(function(){m.textContent='No se pudo enviar. Escanea el QR otra vez.';m.style.color='#ff8a8a';b.disabled=false})};
</script></body></html>
RSHTML

if [ -f logo.png ]; then
  python3 -c "import PIL" 2>/dev/null || python3 -m pip install --quiet pillow 2>/dev/null || python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null || true
  python3 - <<'ICONS' || echo "Iconos por defecto"
from PIL import Image, ImageDraw
import glob
src = Image.open('logo.png').convert('RGB')
w, h = src.size
g = src.convert('L')
px = g.load()
def bright(y): return max(px[x, y] for x in range(w)) > 60
runs, st = [], None
for y in range(h):
    b = bright(y)
    if b and st is None: st = y
    if not b and st is not None: runs.append([st, y]); st = None
if st is not None: runs.append([st, h])
merged = []
for r in runs:
    if merged and r[0] - merged[-1][1] < h * 0.03: merged[-1][1] = r[1]
    else: merged.append(r)
y0, y1 = (merged[0] if len(merged)>=2 else (0, h))
band = src.crop((0, y0, w, y1))
bb = band.convert('L').point(lambda p: 255 if p > 60 else 0).getbbox()
emb = band.crop(bb) if bb else band
def icon(size, frac, circle=False):
    im = Image.new('RGB', (size, size), (0, 0, 0))
    e = emb.copy()
    k = size * frac / max(e.size)
    e = e.resize((max(1, int(e.width * k)), max(1, int(e.height * k))), Image.LANCZOS)
    im.paste(e, ((size - e.width) // 2, (size - e.height) // 2))
    if circle:
        m = Image.new('L', (size, size), 0)
        ImageDraw.Draw(m).ellipse((0, 0, size - 1, size - 1), fill=255)
        out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        out.paste(im, (0, 0), m)
        return out
    return im
legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
res = 'android/app/src/main/res/'
for d in legacy:
    base = res + 'mipmap-' + d + '/'
    if glob.glob(base):
        icon(legacy[d], 0.78).save(base + 'ic_launcher.png')
        icon(legacy[d], 0.70, True).save(base + 'ic_launcher_round.png')
        icon(fore[d], 0.50).save(base + 'ic_launcher_foreground.png')
print('iconos ok')
ICONS
fi

sed -i 's#<application#<application android:usesCleartextTraffic="true"#' $MAN
sed -i 's#</application>#    <activity android:name=".PlayerActivity" android:exported="false" android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize" android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen" />\n    </application>#' $MAN
sed -i 's#</application>#    <activity android:name=".VlcPlayerActivity" android:exported="false" android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize" android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen" />\n    </application>#' $MAN
sed -i '/^dependencies {/a\    implementation "androidx.media3:media3-exoplayer:1.4.1"\n    implementation "androidx.media3:media3-exoplayer-hls:1.4.1"\n    implementation "androidx.media3:media3-ui:1.4.1"\n    implementation "org.jellyfin.media3:media3-ffmpeg-decoder:1.4.1+1"\n    implementation "org.videolan.android:libvlc-all:3.6.0"' android/app/build.gradle
sed -i '/defaultConfig {/a\        ndk { abiFilters "armeabi-v7a", "arm64-v8a" }' android/app/build.gradle

# versionCode debe subir en cada compilación para que Android acepte la actualización
sed -i "s/versionCode [0-9]\+/versionCode ${VC}/; s/versionName \"[^\"]*\"/versionName \"3.0.${VC}\"/" android/app/build.gradle

python3 patch_tv.py .

npx cap sync android

# Sincronizar iOS solamente si el proyecto pudo crearse.
if [ "$IOS_READY" -eq 1 ] && [ -d ios ]; then
  npx cap sync ios
  echo "iOS sincronizado correctamente. La compilación/firma final requiere macOS + Xcode."
fi

cd android
chmod +x gradlew
TASK=assembleDebug
if [ -n "${KEYSTORE_FILE:-}" ] && [ -f "${KEYSTORE_FILE:-}" ]; then TASK=assembleRelease; fi
./gradlew $TASK --no-daemon || {
  sed -i '/media3-ffmpeg-decoder/d' app/build.gradle
  ./gradlew $TASK --no-daemon
}
cd ..

# Salida final: dist/ULTRA4K.apk
mkdir -p dist
if [ "$TASK" = "assembleRelease" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
  "$BT/zipalign" -f -p 4 android/app/build/outputs/apk/release/app-release-unsigned.apk dist/aligned.apk
  "$BT/apksigner" sign --ks "$KEYSTORE_FILE" --ks-pass env:KEYSTORE_PASSWORD --key-pass env:KEY_PASSWORD \
      --ks-key-alias "$KEY_ALIAS" --out dist/ULTRA4K.apk dist/aligned.apk
  rm -f dist/aligned.apk
  echo "APK firmado: dist/ULTRA4K.apk"
else
  cp android/app/build/outputs/apk/debug/app-debug.apk dist/ULTRA4K.apk
  echo "AVISO: sin llave de firma (KEYSTORE_FILE). Se generó APK debug; la firma cambia en cada equipo, por lo que"
  echo "       las actualizaciones automáticas solo funcionan entre APK firmados con la MISMA llave."
fi

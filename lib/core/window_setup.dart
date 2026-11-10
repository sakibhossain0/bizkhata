import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Sizes the desktop window to the screen it opens on.
///
/// Small laptop screens (e.g. 1920×1080 at 150% = 1280×720 logical) could not
/// fit the old fixed 1366×840 window, which pushed the title-bar buttons off
/// screen. Now the window opens maximized the first time, and afterwards
/// restores the last size/position — but only if that still fits a connected
/// display.
Future<void> setupDesktopWindow() async {
  await windowManager.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  Size work = const Size(1280, 680);
  List<Display> displays = const [];
  try {
    final primary = await screenRetriever.getPrimaryDisplay();
    work = primary.visibleSize ?? primary.size;
    displays = await screenRetriever.getAllDisplays();
  } catch (_) {
    // Fall back to a size that fits almost any screen.
  }

  final normal = Size(math.min(1440, work.width * 0.92), math.min(900, work.height * 0.92));
  final minimum = Size(math.min(960, work.width), math.min(600, work.height));

  final saved = _parseRect(prefs.getString(_kBounds));
  final wasMaximized = prefs.getBool(_kMaximized) ?? true;
  final savedFits = saved != null && displays.any((d) => _fits(saved, d));

  // No backgroundColor here: on Windows, window_manager applies it with
  // SetWindowCompositionAttribute, which paints over the system title bar too.
  // The title then showed on a black box and the minimize / maximize / close
  // buttons faded out and stopped responding.
  final options = WindowOptions(
    size: savedFits ? saved.size : normal,
    minimumSize: minimum,
    center: !savedFits,
    title: 'BizKhata',
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    if (savedFits) await windowManager.setBounds(saved);
    if (!savedFits || wasMaximized) await windowManager.maximize();
    await windowManager.show();
    await windowManager.focus();
  });
  windowManager.addListener(_WindowStateSaver(prefs));
}

const _kBounds = 'window_bounds';
const _kMaximized = 'window_maximized';

Rect? _parseRect(String? s) {
  if (s == null) return null;
  final p = s.split(',').map(double.tryParse).toList();
  if (p.length != 4 || p.any((v) => v == null)) return null;
  return Rect.fromLTWH(p[0]!, p[1]!, p[2]!, p[3]!);
}

/// The window's title bar must land on the display and the window must not be
/// bigger than its work area.
bool _fits(Rect r, Display d) {
  final pos = d.visiblePosition ?? Offset.zero;
  final size = d.visibleSize ?? d.size;
  final area = pos & size;
  return r.width <= size.width + 1 &&
      r.height <= size.height + 1 &&
      area.contains(r.topLeft + const Offset(40, 12)) &&
      area.contains(r.topRight + const Offset(-40, 12));
}

class _WindowStateSaver with WindowListener {
  final SharedPreferences prefs;
  _WindowStateSaver(this.prefs);
  Timer? _debounce;

  void _saveBounds() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      if (await windowManager.isMaximized() || await windowManager.isMinimized()) return;
      final b = await windowManager.getBounds();
      await prefs.setString(_kBounds, '${b.left},${b.top},${b.width},${b.height}');
    });
  }

  @override
  void onWindowResized() => _saveBounds();

  @override
  void onWindowMoved() => _saveBounds();

  @override
  void onWindowMaximize() => prefs.setBool(_kMaximized, true);

  @override
  void onWindowUnmaximize() {
    prefs.setBool(_kMaximized, false);
    _saveBounds();
  }
}

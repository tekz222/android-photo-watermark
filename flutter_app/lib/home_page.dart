import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models.dart';
import 'watermark_engine.dart';

/// How many of the selected photos to render in the live preview.
const int kMaxPreview = 5;

/// A rendered preview plus its aspect ratio, so its frame can match the image.
class _Preview {
  _Preview(this.bytes, this.aspect);
  final Uint8List bytes;
  final double aspect; // width / height
}

/// Outcome of a save run, shown in the persistent result banner.
class _ProcessResult {
  _ProcessResult(
      {required this.saved, required this.failed, required this.album});
  final int saved;
  final int failed;
  final String album;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();

  final List<String> _photoPaths = []; // internal copies (survive restarts)
  final List<LogoItem> _bottomLogos = [];
  final List<LogoItem> _topLeftLogos = [];
  LogoItem? _cornerLogo;

  int _nextLogoId = 0;
  int _fileSeq = 0;
  bool _importing = false;
  int _importDone = 0; // photos copied so far (for the loading message)
  int _importTotal = 0; // photos being copied in the current import
  int _previewTotal = 0; // photos expected in the preview being rendered
  bool _renderingPreview = false; // a preview render is in progress
  bool _checkingLogos = false; // logos being checked/added (OCR + similarity)
  int _checkDone = 0;
  int _checkTotal = 0;

  // Adjustments (percent of the photo's shortest side).
  // Size and left margin are SHARED by the bottom and top rows.
  double _logoSize = 22;
  double _leftMargin = 1;
  double _logoOpacity = 90; // shared by both rows (not the main logo)
  double _bottomMargin = 2; // distance from the bottom edge
  double _topMargin = 2; // distance from the top edge
  double _cornerHeight = 22, _cornerMargin = 2;
  bool _centered = false; // bottom row: false = left-to-right, true = centered
  double _logoSpacing = 0; // horizontal gap between logos (both rows)

  // Text overlays (always centered horizontally on the photo).
  final List<TextItem> _texts = [];
  int _nextTextId = 0;
  final Map<int, Uint8List> _textPng = {}; // rasterized text, by TextItem id
  final Map<int, double> _textRatio = {}; // glyph-box / PNG height, by id
  final Map<int, String> _textSigCache = {}; // look snapshot, for invalidation

  // ---- Save state: incremental save into ONE album per project ----
  final Set<String> _savedPaths = {}; // photo paths already saved this project
  String? _currentAlbum; // album reused for the whole project
  _ProcessResult? _lastResult; // persistent result banner

  // Preview state.
  final Map<String, Uint8List> _photoCache = {};
  // Small downscaled copies used ONLY for the live preview (fast re-renders).
  final Map<String, Uint8List> _previewPhoto = {}; // by photo path
  final Map<int, Uint8List> _previewLogo = {}; // by logo id
  List<_Preview> _previews = [];
  int _previewToken = 0;
  Timer? _debounce;

  // Processing state.
  bool _processing = false;
  bool _cancelRequested = false; // user asked to stop after the current image
  int _done = 0;
  int _total = 0;

  bool get _hasAnyLogo =>
      _bottomLogos.isNotEmpty || _topLeftLogos.isNotEmpty || _cornerLogo != null;

  /// Anything to draw on the photos: a logo or a non-empty text.
  bool get _hasAnyContent =>
      _hasAnyLogo || _texts.any((t) => t.text.trim().isNotEmpty);

  /// Photos selected but not yet saved in this project.
  List<String> get _unsavedPaths =>
      _photoPaths.where((p) => !_savedPaths.contains(p)).toList();

  /// Controls (including the main-logo options) stay disabled until at least
  /// one photo is added, and lock again once the project has been saved (an
  /// album exists) — only adding more photos stays available after that.
  bool get _controlsEnabled =>
      !_processing && _currentAlbum == null && _photoPaths.isNotEmpty;
  bool get _canProcess =>
      !_processing && _hasAnyContent && _unsavedPaths.isNotEmpty;
  bool get _allSaved =>
      _photoPaths.isNotEmpty && _hasAnyContent && _unsavedPaths.isEmpty;

  @override
  void initState() {
    super.initState();
    _loadProject();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // ---- Persistence (survives the app being closed/killed) ----

  Future<String> _copyBytesToApp(Uint8List bytes, String sub) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/$sub');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    final file =
        File('${folder.path}/${DateTime.now().microsecondsSinceEpoch}_${_fileSeq++}');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  // Persistence is intentionally DISABLED: the working project lives only in
  // memory. Minimizing / switching apps keeps it (the app stays suspended in
  // memory), but fully closing the app starts fresh. No-op kept so existing
  // call sites stay valid.
  Future<void> _saveProject() async {}

  Future<void> _loadProject() async {
    // Cold start = the app was closed: begin a fresh project and wipe any
    // leftover image copies from a previous run. (Minimizing does NOT trigger a
    // relaunch, so this only runs on a real close/relaunch.)
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final sub in ['photos', 'logos']) {
        final d = Directory('${dir.path}/$sub');
        if (d.existsSync()) d.deleteSync(recursive: true);
      }
    } catch (_) {}
    await _installDefaultCorner();
    _schedulePreview();
  }

  /// Installs the bundled default main (top-right) logo.
  Future<void> _installDefaultCorner() async {
    final data = await rootBundle.load('assets/default_corner_logo.png');
    final bytes = data.buffer.asUint8List();
    final path = await _copyBytesToApp(bytes, 'logos');
    final fp = _imageSig(bytes);
    if (!mounted) return;
    setState(() => _cornerLogo = LogoItem(_nextLogoId++, path,
        'asset:default_corner', bytes, fp,
        const <String>{}, const <String>{}));
  }

  // ---- Picking ----

  Future<void> _pickPhotos() async {
    if (_processing) return; // every button except Cancel is off during a save
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    setState(() {
      _importing = true;
      _importDone = 0;
      _importTotal = picked.length;
    });
    // Copy in parallel so importing many photos is fast; bump a counter as each
    // finishes so the UI can show "Carregando fotos… X de Y".
    var done = 0;
    final paths = await Future.wait(picked.map((x) async {
      final bytes = await x.readAsBytes();
      final path = await _copyBytesToApp(bytes, 'photos');
      _photoCache[path] = bytes;
      if (mounted) setState(() => _importDone = ++done);
      return path;
    }));
    setState(() {
      _photoPaths.addAll(paths);
      _importing = false;
    });
    _schedulePreview();
    // If this project was already saved, the new photos go straight into the
    // same album (only the unsaved ones get processed).
    if (_currentAlbum != null && !_processing) _saveAll();
  }

  /// Normalized logo name for de-duplication: base filename, no extension,
  /// lowercased.
  String _logoName(String raw) {
    var n = raw.split('/').last.split('\\').last;
    final dot = n.lastIndexOf('.');
    if (dot > 0) n = n.substring(0, dot);
    return n.toLowerCase().trim();
  }

  /// The same logo can never be used twice: block exactly-equal names AND
  /// near-duplicates where one name contains the other (e.g. "casa_lutaif" vs
  /// "casa_lutaif2" / "casa_lutaif_pouco_texto").
  bool _namesRelated(String a, String b) =>
      a.isNotEmpty &&
      b.isNotEmpty &&
      (a == b || a.contains(b) || b.contains(a));

  Future<void> _pickLogos(List<LogoItem> target) async {
    // Logos are picked as image files (same picker as the photos).
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    setState(() {
      _checkingLogos = true;
      _checkDone = 0;
      _checkTotal = picked.length;
    });
    // De-dup against logos already in the rows AND the main logo, by file name
    // and by EXACT image (a cheap byte signature — no decoding, so it can't
    // freeze). No visual/AI similarity, no OCR.
    final existing = [
      ..._bottomLogos,
      ..._topLeftLogos,
      if (_cornerLogo != null) _cornerLogo!,
    ];
    final usedNames = existing.map((e) => _logoName(e.sourceKey)).toList();
    final usedSigs = existing.map((e) => e.phash).toSet();
    var skipped = 0;
    try {
      for (var i = 0; i < picked.length; i++) {
        setState(() => _checkDone = i + 1);
        await Future<void>.delayed(const Duration(milliseconds: 16));
        try {
          final x = picked[i];
          final bytes = await x.readAsBytes();
          final name = _logoName(x.name);
          final sig = _imageSig(bytes);
          final dupName =
              name.isNotEmpty && usedNames.any((u) => _namesRelated(u, name));
          final dupSame = usedSigs.contains(sig);
          if (dupName || dupSame) {
            skipped++;
            continue;
          }
          final path = await _copyBytesToApp(bytes, 'logos');
          target.add(LogoItem(_nextLogoId++, path, x.name, bytes, sig,
              const <String>{}, const <String>{}));
          usedNames.add(name);
          usedSigs.add(sig);
        } catch (_) {
          // One bad logo shouldn't abort the rest.
        }
      }
    } finally {
      if (mounted) setState(() => _checkingLogos = false);
    }
    if (skipped > 0) {
      _snack('$skipped logo(s) ignorada(s): mesma imagem ou mesmo nome de uma '
          'já no projeto.');
    }
    _schedulePreview();
  }

  /// Cheap identity signature of the raw image bytes (length + ~64 sampled
  /// bytes). No decoding, so it never blocks — identifies the EXACT same image.
  int _imageSig(Uint8List b) {
    final n = b.length;
    var h = n & 0x7fffffff;
    if (n > 0) {
      final step = (n ~/ 64) < 1 ? 1 : (n ~/ 64);
      for (var i = 0; i < n; i += step) {
        h = (h * 31 + b[i]) & 0x7fffffff;
      }
    }
    return h;
  }

  Future<void> _pickCornerLogo() async {
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _importing = true);
    final path = await _copyBytesToApp(bytes, 'logos');
    final fp = _imageSig(bytes);
    setState(() {
      _cornerLogo = LogoItem(_nextLogoId++, path, x.name, bytes, fp,
          const <String>{}, const <String>{});
      _importing = false;
    });
    _schedulePreview();
  }

  // ---- Preview ----

  void _schedulePreview() {
    _saveProject();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _recomputePreviews);
  }

  Future<void> _recomputePreviews() async {
    final token = ++_previewToken;
    final photos = _photoPaths.take(kMaxPreview).toList();
    if (photos.isEmpty || !_hasAnyContent) {
      setState(() {
        _previews = [];
        _previewTotal = 0;
        _renderingPreview = false;
      });
      return;
    }
    setState(() {
      _previewTotal = photos.length;
      _renderingPreview = true;
    });
    // Prepare small copies of the logos once (cached) so re-renders are cheap.
    final allLogos = [
      ..._bottomLogos,
      ..._topLeftLogos,
      if (_cornerLogo != null) _cornerLogo!,
    ];
    for (final e in allLogos) {
      _previewLogo[e.id] ??=
          await compute(downscaleImage, (e.bytes, 512, true));
      if (token != _previewToken) return;
    }
    await _ensureTextPngs();
    if (token != _previewToken) return;
    // Render every preview from the SMALL sources, then show all at once.
    final results = <_Preview>[];
    for (final path in photos) {
      final full = _photoCache[path] ??= await File(path).readAsBytes();
      if (token != _previewToken) return;
      final small =
          _previewPhoto[path] ??= await compute(downscaleImage, (full, 1280, false));
      if (token != _previewToken) return;
      final out = await compute(renderWatermark, _previewRequest(small));
      if (token != _previewToken) return;
      final codec = await ui.instantiateImageCodec(out);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final aspect = image.height == 0 ? 1.0 : image.width / image.height;
      image.dispose();
      codec.dispose();
      if (token != _previewToken) return;
      results.add(_Preview(out, aspect));
    }
    if (token == _previewToken && mounted) {
      setState(() {
        _previews = results;
        _renderingPreview = false;
      });
    }
  }

  /// Watermark request for the live preview, using the small cached photo and
  /// logo copies (the saved image still uses the full-resolution originals).
  WatermarkRequest _previewRequest(Uint8List photoSmall) {
    Uint8List logo(LogoItem e) => _previewLogo[e.id] ?? e.bytes;
    return WatermarkRequest(
      photoBytes: photoSmall,
      bottomLogos: _bottomLogos.map(logo).toList(),
      topLeftLogos: _topLeftLogos.map(logo).toList(),
      cornerLogo: _cornerLogo == null ? null : logo(_cornerLogo!),
      bottomHeight: _logoSize / 100,
      bottomMargin: _bottomMargin / 100,
      bottomLeft: _leftMargin / 100,
      topLeftHeight: _logoSize / 100,
      topLeftTop: _topMargin / 100,
      topLeftLeft: _leftMargin / 100,
      cornerHeight: _cornerHeight / 100,
      cornerMargin: _cornerMargin / 100,
      rowOpacity: _logoOpacity / 100,
      centered: _centered,
      spacing: _logoSpacing / 100,
      textOverlays: _textOverlays(),
      quality: 85,
    );
  }

  WatermarkRequest _request(Uint8List photoBytes,
      {int? maxDim, int quality = 95, bool png = false}) {
    return WatermarkRequest(
      photoBytes: photoBytes,
      bottomLogos: _bottomLogos.map((e) => e.bytes).toList(),
      topLeftLogos: _topLeftLogos.map((e) => e.bytes).toList(),
      cornerLogo: _cornerLogo?.bytes,
      bottomHeight: _logoSize / 100,
      bottomMargin: _bottomMargin / 100,
      bottomLeft: _leftMargin / 100,
      topLeftHeight: _logoSize / 100,
      topLeftTop: _topMargin / 100,
      topLeftLeft: _leftMargin / 100,
      cornerHeight: _cornerHeight / 100,
      cornerMargin: _cornerMargin / 100,
      rowOpacity: _logoOpacity / 100,
      centered: _centered,
      spacing: _logoSpacing / 100,
      textOverlays: _textOverlays(),
      png: png,
      maxDim: maxDim,
      quality: quality,
    );
  }

  // ---- Text overlays ----

  /// Fonts that ship with Windows (the app falls back to the default font on
  /// systems that don't have one of them).
  static const List<String> kTextFonts = [
    'Arial',
    'Arial Black',
    'Bahnschrift',
    'Calibri',
    'Cambria',
    'Comic Sans MS',
    'Consolas',
    'Courier New',
    'Georgia',
    'Impact',
    'Lucida Console',
    'Segoe UI',
    'Segoe Print',
    'Segoe Script',
    'Tahoma',
    'Times New Roman',
    'Trebuchet MS',
    'Verdana',
  ];

  static const List<int> _swatches = [
    0xFFFFFFFF,
    0xFF000000,
    0xFFE53935,
    0xFFFB8C00,
    0xFFFDD835,
    0xFF43A047,
    0xFF1E88E5,
    0xFF8E24AA,
    0xFFEC407A,
    0xFF05B2AE,
  ];

  /// Snapshot of the properties that change the rasterized PNG. Size and
  /// vertical position are applied when compositing, so moving/resizing a text
  /// never forces a re-raster.
  String _textSig(TextItem t) =>
      '${t.text}|${t.fontFamily}|${t.bold}|${t.italic}|${t.color}|'
      '${t.rainbow}|${t.outline}|${t.outlineColor}|${t.outlineWidth}';

  /// Re-rasterizes any text whose look changed. Runs on the UI thread (canvas
  /// text drawing can't run in an isolate) but is fast — it's only text.
  Future<void> _ensureTextPngs() async {
    for (final t in List<TextItem>.from(_texts)) {
      if (t.text.trim().isEmpty) continue;
      final sig = _textSig(t);
      if (_textSigCache[t.id] == sig && _textPng.containsKey(t.id)) continue;
      try {
        final r = await _rasterizeText(t);
        _textPng[t.id] = r.png;
        _textRatio[t.id] = r.contentRatio;
        _textSigCache[t.id] = sig;
      } catch (_) {
        // Couldn't render this text: drop it (never show a stale look) and
        // keep going with the rest.
        _textPng.remove(t.id);
        _textRatio.remove(t.id);
        _textSigCache.remove(t.id);
      }
    }
  }

  List<TextOverlay> _textOverlays() => [
        for (final t in _texts)
          if (t.text.trim().isNotEmpty && _textPng[t.id] != null)
            TextOverlay(
              png: _textPng[t.id]!,
              height: t.heightPct / 100,
              top: t.topPct / 100,
              contentRatio: _textRatio[t.id] ?? 1.0,
            ),
      ];

  /// Draws one text into a transparent PNG with Flutter's text engine (system
  /// fonts, outline, rainbow gradient). Rendered big so it stays sharp when
  /// scaled onto full-resolution photos, but capped in width so the pure-Dart
  /// decode in the engine stays cheap and long texts are never clipped.
  Future<({Uint8List png, double contentRatio})> _rasterizeText(
      TextItem t) async {
    const maxWidth = 2560.0, maxHeight = 1600.0;
    var fontSize = 320.0;
    var m = _measureText(t, fontSize);
    final totalW = m.measure.width + m.pad * 2;
    final totalH = m.measure.height + m.pad * 2;
    final scale = [maxWidth / totalW, maxHeight / totalH, 1.0]
        .reduce((a, b) => a < b ? a : b);
    if (scale < 1.0) {
      fontSize *= scale;
      m = _measureText(t, fontSize);
    }
    final textW = m.measure.width;
    final textH = m.measure.height;
    final pad = m.pad;

    TextPainter painterWith(Paint foreground) => TextPainter(
          text: TextSpan(
              text: t.text, style: m.style.copyWith(foreground: foreground)),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
        )..layout(minWidth: textW);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final origin = Offset(pad, pad);
    if (t.outline) {
      painterWith(Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = m.strokeW
            ..strokeJoin = StrokeJoin.round
            ..color = Color(t.outlineColor))
          .paint(canvas, origin);
    }
    final fill = Paint();
    if (t.rainbow) {
      fill.shader = ui.Gradient.linear(
        Offset(pad, 0),
        Offset(pad + textW, 0),
        const [
          Color(0xFFE53935),
          Color(0xFFFB8C00),
          Color(0xFFFDD835),
          Color(0xFF43A047),
          Color(0xFF1E88E5),
          Color(0xFF8E24AA),
        ],
        const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
      );
    } else {
      fill.color = Color(t.color);
    }
    painterWith(fill).paint(canvas, origin);

    final picture = recorder.endRecording();
    final pngW = (textW + pad * 2).ceil().clamp(1, 8192);
    final pngH = (textH + pad * 2).ceil().clamp(1, 8192);
    final image = await picture.toImage(pngW, pngH);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('PNG encode failed');
    return (
      png: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      contentRatio: textH / pngH,
    );
  }

  /// Text style + layout for [t] at [fontSize]. [pad] leaves room for the
  /// outline stroke and for glyphs that overhang (italics, swashes).
  ({TextStyle style, double strokeW, double pad, TextPainter measure})
      _measureText(TextItem t, double fontSize) {
    final style = TextStyle(
      fontFamily: t.fontFamily,
      fontSize: fontSize,
      fontWeight: t.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
    );
    final strokeW = t.outline ? fontSize * (t.outlineWidth / 100) : 0.0;
    // Measure once so multi-line texts are centered line by line.
    final measure = TextPainter(
      text: TextSpan(text: t.text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    return (
      style: style,
      strokeW: strokeW,
      pad: strokeW + fontSize * 0.12,
      measure: measure,
    );
  }

  // ---- Saving ----

  Future<void> _saveAll() async {
    if (_processing || !_hasAnyContent) return;
    if (_unsavedPaths.isEmpty) return; // everything is already saved
    // Keep the device awake so a long save isn't interrupted by auto-lock.
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    // Reuse the project's album; create one (named by date/time) on first save.
    final album = _currentAlbum ?? _nextAlbum();
    // Snapshot so a cancel can restore the exact pre-save state.
    final prevSaved = Set<String>.from(_savedPaths);
    final prevAlbum = _currentAlbum;
    final prevResult = _lastResult;
    setState(() {
      _processing = true;
      _cancelRequested = false;
      _currentAlbum = album;
      _lastResult = null;
      _done = 0;
      _total = _unsavedPaths.length;
    });

    await _ensureTextPngs();

    // Process only photos not yet saved.
    final processed = <String>{};
    var saved = 0, failed = 0;
    while (mounted) {
      String? next;
      for (final path in _unsavedPaths) {
        if (!processed.contains(path)) {
          next = path;
          break;
        }
      }
      if (next == null) break;
      processed.add(next);
      try {
        final bytes = _photoCache[next] ?? await File(next).readAsBytes();
        // High-quality JPEG: same kind of file size as the original photo
        // (lossless PNG made 10 MB+ files).
        final out =
            await compute(renderWatermark, _request(bytes, quality: 92));
        final ts = DateTime.now().microsecondsSinceEpoch;
        final dir = await _albumDir(album);
        await File('${dir.path}${Platform.pathSeparator}watermarked_$ts.jpg')
            .writeAsBytes(out);
        _savedPaths.add(next);
        saved++;
      } catch (_) {
        failed++;
      }
      setState(() {
        _done = processed.length;
        _total = processed.length + _unsavedPaths.length;
      });
      // Cancel takes effect AFTER the current image finished saving.
      if (_cancelRequested) break;
    }

    try {
      await WakelockPlus.disable();
    } catch (_) {}
    if (_cancelRequested) {
      if (!mounted) return;
      // Restore the app to exactly how it was before saving started.
      setState(() {
        _processing = false;
        _cancelRequested = false;
        _savedPaths
          ..clear()
          ..addAll(prevSaved);
        _currentAlbum = prevAlbum;
        _lastResult = prevResult;
      });
      _snack('Salvamento cancelado.');
      return;
    }
    await _addHistory(album, saved, failed);
    await _saveProject();
    if (!mounted) return;
    setState(() {
      _processing = false;
      _lastResult = _ProcessResult(saved: saved, failed: failed, album: album);
    });
  }

  /// Where photos are saved: Pictures\JCV Watermarker\<album> (falls back to
  /// the app documents folder if the Pictures folder can't be found).
  Future<Directory> _albumDir(String album) async {
    Directory base;
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null &&
        Directory('$userProfile${Platform.pathSeparator}Pictures')
            .existsSync()) {
      base = Directory('$userProfile${Platform.pathSeparator}Pictures');
    } else {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(
        '${base.path}${Platform.pathSeparator}JCV Watermarker'
        '${Platform.pathSeparator}$album');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ---- Album numbering + history (shared_preferences) ----

  String _nextAlbum() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}-${two(d.minute)}-${two(d.second)}';
  }

  Future<void> _addHistory(String album, int saved, int failed) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('runs') ?? [];
    list.add(jsonEncode({
      'album': album,
      'time': DateTime.now().millisecondsSinceEpoch,
      'saved': saved,
      'failed': failed,
    }));
    await p.setStringList('runs', list);
  }

  Future<List<Map<String, dynamic>>> _getHistory() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('runs') ?? [];
    return list.reversed
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList();
  }

  String _fmtDate(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _openHistory() async {
    final runs = await _getHistory();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Histórico de salvamentos'),
        content: runs.isEmpty
            ? const Text('Nenhum salvamento ainda.')
            : SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: runs.map((r) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(r['album'] as String),
                      subtitle: Text(
                          '${r['saved']} foto(s) · ${_fmtDate(r['time'] as int)}'),
                    );
                  }).toList(),
                ),
              ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Fechar')),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: Image.asset(
                'assets/appbar_logo.png',
                width: 30,
                height: 30,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 9),
            const Text(
              'JCV Watermarker',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            // Available once there are photos (or a saved project) to clear;
            // off while saving (only Cancel works then).
            onPressed: (!_processing &&
                    (_photoPaths.isNotEmpty || _savedPaths.isNotEmpty))
                ? _confirmNewProject
                : null,
            child: const Text('Novo projeto'),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Histórico',
            onPressed: _processing ? null : _openHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_importing) const LinearProgressIndicator(minHeight: 4),
          if (_checkingLogos) ...[
            LinearProgressIndicator(
              minHeight: 4,
              value: _checkTotal > 0 ? _checkDone / _checkTotal : null,
            ),
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Verificando logo $_checkDone de $_checkTotal…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          if (_photoPaths.isNotEmpty && _hasAnyContent) _previewBar(),
          Expanded(
            // Content column capped so it doesn't stretch across a wide
            // desktop window (no effect on phones/tablets).
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_lastResult != null) ...[
                      _resultBanner(),
                      const SizedBox(height: 16),
                    ],
                    if (_currentAlbum != null && !_processing) ...[
                      _lockedBanner(),
                      const SizedBox(height: 16),
                    ],
                    _photosCard(),
                    const SizedBox(height: 16),
                    _logoCard(
                      number: 2,
                      title: 'Logos da base',
                      placement: Placement.bottom,
                      items: _bottomLogos,
                      hint: 'Da esquerda para a direita (ou centralizadas) na '
                          'base. Tamanho, espaço, opacidade e distância da '
                          'esquerda valem para as de cima e de baixo.',
                      onAdd: () => _pickLogos(_bottomLogos),
                      sliders: [
                        _alignmentChooser(),
                        _slider('Tamanho (todas)', _logoSize, 5, 30,
                            (v) => setState(() => _logoSize = v)),
                        _slider('Espaço entre as logos (todas)', _logoSpacing,
                            0, 10, (v) => setState(() => _logoSpacing = v)),
                        if (!_centered)
                          _slider('Distância da borda esquerda (todas)',
                              _leftMargin, 0, 15,
                              (v) => setState(() => _leftMargin = v)),
                        _slider('Opacidade (todas)', _logoOpacity, 0, 100,
                            (v) => setState(() => _logoOpacity = v)),
                        _slider('Distância da borda inferior', _bottomMargin,
                            0, 15, (v) => setState(() => _bottomMargin = v)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _logoCard(
                      number: 3,
                      title: 'Logos do canto superior esquerdo',
                      placement: Placement.topLeft,
                      items: _topLeftLogos,
                      hint: 'Sempre da esquerda para a direita, no topo. '
                          'Tamanho, espaço, opacidade e distância da esquerda '
                          'valem para as de cima e de baixo.',
                      onAdd: () => _pickLogos(_topLeftLogos),
                      sliders: [
                        _slider('Tamanho (todas)', _logoSize, 5, 30,
                            (v) => setState(() => _logoSize = v)),
                        _slider('Espaço entre as logos (todas)', _logoSpacing,
                            0, 10, (v) => setState(() => _logoSpacing = v)),
                        _slider('Distância da borda esquerda (todas)',
                            _leftMargin, 0, 15,
                            (v) => setState(() => _leftMargin = v)),
                        _slider('Opacidade (todas)', _logoOpacity, 0, 100,
                            (v) => setState(() => _logoOpacity = v)),
                        _slider('Distância da borda superior', _topMargin, 0,
                            15, (v) => setState(() => _topMargin = v)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _cornerCard(),
                    const SizedBox(height: 16),
                    _textsCard(),
                    const SizedBox(height: 16),
                    _actionArea(),
                    const SizedBox(height: 24),
                    Center(
                      child: Text(
                        'Build ${const String.fromEnvironment('APP_BUILD', defaultValue: 'dev')}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).disabledColor),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewBar() {
    return Material(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _photoPaths.length <= 1
                  ? 'Pré-visualização (1ª foto)'
                  : 'Pré-visualização (primeiras ${_photoPaths.length.clamp(0, kMaxPreview)} fotos) — arraste para o lado',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 208,
              child: _previews.isEmpty
                  ? Center(
                      child: Text(
                        'Gerando pré-visualização…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _previews.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => _previewTile(i),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewTile(int i) {
    final p = _previews[i];
    // Frame matches the image's aspect ratio (no big empty rectangle), capped
    // to the available height/width.
    const maxH = 196.0;
    final maxW = MediaQuery.of(context).size.width * 0.9;
    double w = maxH * p.aspect;
    double h = maxH;
    if (w > maxW) {
      w = maxW;
      h = maxW / p.aspect;
    }
    return Center(
      child: GestureDetector(
        onTap: _processing ? null : () => _openFullscreen(i),
        child: Container(
          // Square corners + light gray frame.
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400, width: 1),
          ),
          child: ClipRect(
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(p.bytes, fit: BoxFit.cover),
                  if (_previews.length > 1)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${i + 1}/${_previews.length}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openFullscreen(int index) {
    // Show ALL preview photos (so you can swipe to ones not rendered yet) and
    // render each at high resolution on demand, so zoom stays sharp.
    final paths = _photoPaths.take(kMaxPreview).toList();
    if (paths.isEmpty) return;
    // Already-rendered low-res previews show instantly; hi-res loads to replace.
    final placeholders = [
      for (var i = 0; i < paths.length; i++)
        i < _previews.length ? _previews[i].bytes : null,
    ];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenViewer(
          initialPage: index,
          itemCount: paths.length,
          placeholders: placeholders,
          loader: (i) => _renderFull(paths[i]),
        ),
      ),
    );
  }

  /// Renders one watermarked photo at FULL resolution (same as the saved file)
  /// so logos stay sharp when zoomed in the viewer.
  Future<Uint8List?> _renderFull(String path) async {
    try {
      final bytes = _photoCache[path] ??= await File(path).readAsBytes();
      await _ensureTextPngs();
      return await compute(
          renderWatermark, _request(bytes, quality: 95));
    } catch (_) {
      return null;
    }
  }

  /// Opens any list of image bytes (e.g. logos) in the zoomable fullscreen
  /// viewer, starting at [index].
  void _openImagesFullscreen(List<Uint8List> images, int index) {
    if (images.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenViewer(
          initialPage: index,
          itemCount: images.length,
          placeholders: images, // already full-res; show immediately
          loader: (i) async => images[i],
        ),
      ),
    );
  }

  Widget _photosCard() {
    return _StepCard(
      number: 1,
      title: 'Selecione as fotos',
      icon: const Icon(Icons.photo_library_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            onPressed: _processing ? null : _pickPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Adicionar fotos'),
          ),
          // Status only while importing photos (no indicator during preview).
          if (_importing) ...[
            const SizedBox(height: 12),
            Text(
              _importTotal > 0
                  ? 'Carregando fotos… $_importDone de $_importTotal'
                  : 'Carregando…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_photoPaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${_photoPaths.length} foto(s)',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            SizedBox(
              height: 76,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photoPaths.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _thumb(
                  enabled: _controlsEnabled,
                  child: Image.file(File(_photoPaths[i]), fit: BoxFit.cover),
                  onRemove: () {
                    final path = _photoPaths[i];
                    setState(() => _photoPaths.removeAt(i));
                    _photoCache.remove(path);
                    File(path).delete().ignore();
                    _schedulePreview();
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _logoCard({
    required int number,
    required String title,
    required Placement placement,
    required List<LogoItem> items,
    required String hint,
    required VoidCallback onAdd,
    required List<Widget> sliders,
  }) {
    return _StepCard(
      number: number,
      title: title,
      icon: _PlacementIcon(placement),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed:
                (_photoPaths.isEmpty || !_controlsEnabled) ? null : onAdd,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Adicionar logos'),
          ),
          const SizedBox(height: 8),
          Text(
            _photoPaths.isEmpty
                ? 'Adicione as fotos primeiro; depois envie as logos.'
                : hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${items.length} logo(s)',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            if (items.length > 1)
              Text('Segure e arraste para cima/baixo para reordenar.',
                  style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: _controlsEnabled,
              itemCount: items.length,
              onReorder: (oldIndex, newIndex) {
                if (!_controlsEnabled) return;
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  items.insert(newIndex, items.removeAt(oldIndex));
                });
                _schedulePreview();
              },
              itemBuilder: (context, i) {
                final item = items[i];
                return ListTile(
                  key: ValueKey(item.id),
                  contentPadding: EdgeInsets.zero,
                  leading: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _processing
                        ? null
                        : () => _openImagesFullscreen(
                            items.map((e) => e.bytes).toList(), i),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 48,
                        height: 48,
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Image.memory(item.bytes, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                  title: Text('${i + 1}. ${item.sourceKey}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: !_controlsEnabled
                        ? null
                        : () {
                            setState(() => items.removeAt(i));
                            _schedulePreview();
                          },
                  ),
                );
              },
            ),
            ...sliders,
          ],
        ],
      ),
    );
  }

  Widget _cornerCard() {
    return _StepCard(
      number: 4,
      title: 'Logo principal (canto superior direito)',
      icon: const _PlacementIcon(Placement.topRight),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: (_photoPaths.isEmpty || !_controlsEnabled)
                ? null
                : _pickCornerLogo,
            icon: const Icon(Icons.image_outlined),
            label: Text(_cornerLogo == null
                ? 'Adicionar logo principal'
                : 'Trocar logo principal'),
          ),
          const SizedBox(height: 8),
          Text('Uma única logo no canto superior direito.',
              style: Theme.of(context).textTheme.bodySmall),
          if (_cornerLogo != null) ...[
            const SizedBox(height: 12),
            _thumb(
              enabled: _controlsEnabled,
              onTap: _processing
                  ? null
                  : () => _openImagesFullscreen([_cornerLogo!.bytes], 0),
              child: Image.memory(_cornerLogo!.bytes, fit: BoxFit.contain),
              onRemove: () {
                setState(() => _cornerLogo = null);
                _schedulePreview();
              },
            ),
            _slider('Tamanho', _cornerHeight, 5, 40,
                (v) => setState(() => _cornerHeight = v)),
            _slider('Distância do canto', _cornerMargin, 0, 15,
                (v) => setState(() => _cornerMargin = v)),
          ],
        ],
      ),
    );
  }

  Widget _textsCard() {
    return _StepCard(
      number: 5,
      title: 'Textos nas fotos',
      icon: const Icon(Icons.text_fields),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed:
                (_photoPaths.isEmpty || !_controlsEnabled) ? null : _addText,
            icon: const Icon(Icons.title),
            label: const Text('Adicionar texto'),
          ),
          const SizedBox(height: 8),
          Text(
            _photoPaths.isEmpty
                ? 'Adicione as fotos primeiro; depois crie os textos.'
                : 'Sempre centralizado na horizontal. Escolha a fonte do '
                    'computador, as cores, o contorno, o tamanho e a altura.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final t in _texts) _textEditor(t),
        ],
      ),
    );
  }

  void _addText() {
    setState(() => _texts.add(TextItem(id: _nextTextId++)));
    _schedulePreview();
  }

  void _removeText(TextItem t) {
    setState(() {
      _texts.remove(t);
      _textPng.remove(t.id);
      _textRatio.remove(t.id);
      _textSigCache.remove(t.id);
    });
    _schedulePreview();
  }

  Widget _textEditor(TextItem t) {
    final scheme = Theme.of(context).colorScheme;
    void update(VoidCallback change) {
      setState(change);
      _schedulePreview();
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('text_${t.id}'),
                  initialValue: t.text,
                  enabled: _controlsEnabled,
                  maxLines: null,
                  decoration: const InputDecoration(
                    labelText: 'Texto',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    t.text = v;
                    _schedulePreview();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Remover texto',
                icon: const Icon(Icons.delete_outline),
                onPressed: !_controlsEnabled ? null : () => _removeText(t),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Fonte (do computador)',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: kTextFonts.contains(t.fontFamily)
                    ? t.fontFamily
                    : kTextFonts.first,
                isExpanded: true,
                isDense: true,
                items: [
                  for (final f in kTextFonts)
                    DropdownMenuItem(
                      value: f,
                      child: Text(f, style: TextStyle(fontFamily: f)),
                    ),
                ],
                onChanged: !_controlsEnabled
                    ? null
                    : (v) {
                        if (v != null) update(() => t.fontFamily = v);
                      },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('Negrito'),
                selected: t.bold,
                onSelected:
                    !_controlsEnabled ? null : (s) => update(() => t.bold = s),
              ),
              FilterChip(
                label: const Text('Itálico'),
                selected: t.italic,
                onSelected: !_controlsEnabled
                    ? null
                    : (s) => update(() => t.italic = s),
              ),
              FilterChip(
                label: const Text('Contorno'),
                selected: t.outline,
                onSelected: !_controlsEnabled
                    ? null
                    : (s) => update(() => t.outline = s),
              ),
              FilterChip(
                label: const Text('Arco-íris'),
                selected: t.rainbow,
                onSelected: !_controlsEnabled
                    ? null
                    : (s) => update(() => t.rainbow = s),
              ),
            ],
          ),
          if (!t.rainbow) ...[
            const SizedBox(height: 8),
            _colorRow('Cor do texto', t.color, (c) => update(() => t.color = c)),
          ],
          if (t.outline) ...[
            const SizedBox(height: 8),
            _colorRow('Cor do contorno', t.outlineColor,
                (c) => update(() => t.outlineColor = c)),
            _slider('Espessura do contorno', t.outlineWidth, 2, 20,
                (v) => setState(() => t.outlineWidth = v)),
          ],
          _slider('Tamanho do texto', t.heightPct, 2, 30,
              (v) => setState(() => t.heightPct = v)),
          _slider('Altura na foto (0% = topo, 100% = base)', t.topPct, 0, 100,
              (v) => setState(() => t.topPct = v)),
        ],
      ),
    );
  }

  Widget _colorRow(String label, int selected, ValueChanged<int> onPick) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label:', style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in _swatches)
              GestureDetector(
                onTap: !_controlsEnabled ? null : () => onPick(c),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected == c ? primary : Colors.grey.shade600,
                      width: selected == c ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _actionArea() {
    if (_processing) {
      final progress = _total == 0 ? 0.0 : _done / _total;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text('Processando $_done de $_total…', textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            'Mantenha o app aberto.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            // Finishes the current image, then stops and restores the
            // pre-save state. Disabled (shows "Cancelando…") once tapped.
            onPressed: _cancelRequested
                ? null
                : () => setState(() => _cancelRequested = true),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(_cancelRequested ? 'Cancelando…' : 'Cancelar'),
          ),
        ],
      );
    }
    // Everything currently selected has already been saved.
    if (_allSaved && _currentAlbum != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: _pickPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Adicionar mais fotos'),
          ),
          const SizedBox(height: 6),
          Text(
            'Tudo salvo na pasta “$_currentAlbum”. Fotos novas vão para a mesma '
            'pasta. Use “Novo projeto” para começar do zero.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      );
    }
    final firstSave = _currentAlbum == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _canProcess ? _saveAll : null,
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.check_circle_outline),
          label: Text(
              firstSave ? 'Aplicar e salvar tudo' : 'Salvar novas fotos'),
        ),
        const SizedBox(height: 6),
        Text(
          firstSave
              ? 'As imagens são salvas em Imagens\\JCV Watermarker, numa pasta '
                  'nomeada pela data/hora.'
              : 'As novas fotos vão para a mesma pasta “$_currentAlbum”.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _resultBanner() {
    final r = _lastResult!;
    final ok = r.failed == 0;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: ok ? scheme.secondaryContainer : scheme.errorContainer,
      child: ListTile(
        leading: Icon(ok ? Icons.check_circle : Icons.error_outline),
        title: Text(ok
            ? '${r.saved} foto(s) salva(s)'
            : '${r.saved} salva(s), ${r.failed} falharam'),
        subtitle: Text('Pasta: Imagens\\JCV Watermarker\\${r.album}'),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Dispensar',
          onPressed: () => setState(() => _lastResult = null),
        ),
      ),
    );
  }

  /// Shown once a project has been saved: edits are locked, only adding photos
  /// (into the same album) stays available. Makes the locked state obvious and
  /// offers a one-tap way out.
  Widget _lockedBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.lock_outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Projeto já salvo na pasta “$_currentAlbum”. Ajustes, logos e '
                'textos estão travados; fotos novas vão para a mesma pasta com a '
                'mesma configuração. Para editar ou usar outras fotos, comece um '
                'novo projeto.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _confirmNewProject,
              child: const Text('Novo projeto'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmNewProject() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Começar novo projeto?'),
        content: const Text(
            'Isso limpa as fotos, logos e textos atuais. As imagens já salvas '
            'na pasta são mantidas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Novo projeto')),
        ],
      ),
    );
    if (ok == true) _newProject();
  }

  Future<void> _newProject() async {
    _previewToken++; // invalidate any in-flight preview render
    setState(() {
      _photoPaths.clear();
      _bottomLogos.clear();
      _topLeftLogos.clear();
      _cornerLogo = null;
      _savedPaths.clear();
      _currentAlbum = null;
      _lastResult = null;
      _previews = [];
      _previewTotal = 0;
      _renderingPreview = false;
      _importing = false;
      _checkingLogos = false;
      _cancelRequested = false;
      _photoCache.clear();
      _previewPhoto.clear();
      _previewLogo.clear();
      _texts.clear();
      _textPng.clear();
      _textRatio.clear();
      _textSigCache.clear();
      _logoSize = 22;
      _leftMargin = 1;
      _logoOpacity = 90;
      _bottomMargin = 2;
      _topMargin = 2;
      _cornerHeight = 22;
      _cornerMargin = 2;
      _centered = false;
      _logoSpacing = 0;
    });
    await _installDefaultCorner();
    await _saveProject();
  }

  Widget _alignmentChooser() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Alinhamento das logos da base:',
            style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Esquerda → direita'),
              selected: !_centered,
              onSelected: !_controlsEnabled
                  ? null
                  : (s) {
                      setState(() => _centered = false);
                      _schedulePreview();
                    },
            ),
            ChoiceChip(
              label: const Text('Centralizado'),
              selected: _centered,
              onSelected: !_controlsEnabled
                  ? null
                  : (s) {
                      setState(() => _centered = true);
                      _schedulePreview();
                    },
            ),
          ],
        ),
      ],
    );
  }

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.round()}%',
            style: const TextStyle(fontWeight: FontWeight.w500)),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: !_controlsEnabled
              ? null
              : (v) {
                  onChanged(v);
                  _schedulePreview();
                },
        ),
      ],
    );
  }

  Widget _thumb({
    required Widget child,
    required VoidCallback onRemove,
    VoidCallback? onTap,
    bool enabled = true,
  }) {
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 76,
                height: 76,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: child,
              ),
            ),
          ),
          if (enabled)
            Positioned(
              top: 2,
              right: 2,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(2),
                  child:
                      const Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.icon,
    required this.child,
  });

  final int number;
  final String title;
  final Widget icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: scheme.primary,
                  child: Text('$number',
                      style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                ),
                const SizedBox(width: 10),
                SizedBox(width: 28, height: 28, child: icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// A 16:9 frame with the relevant region highlighted.
class _PlacementIcon extends StatelessWidget {
  const _PlacementIcon(this.placement);
  final Placement placement;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(28, 28),
      painter: _PlacementPainter(placement, Theme.of(context).colorScheme.primary),
    );
  }
}

class _PlacementPainter extends CustomPainter {
  _PlacementPainter(this.placement, this.color);
  final Placement placement;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final frameW = size.width;
    final frameH = frameW * 9 / 16;
    final top = (size.height - frameH) / 2;
    final stroke = (frameH * 0.09).clamp(2.0, 4.0);
    final radius = Radius.circular(frameH * 0.14);

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color;
    final frame = RRect.fromRectAndRadius(
      Rect.fromLTWH(stroke / 2, top + stroke / 2, frameW - stroke, frameH - stroke),
      radius,
    );
    canvas.drawRRect(frame, outline);

    final fill = Paint()..color = color;
    final pad = frameW * 0.16;
    switch (placement) {
      case Placement.bottom:
        final barH = frameH * 0.24;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(pad, top + frameH - pad - barH, frameW - pad * 2, barH),
            Radius.circular(barH / 2),
          ),
          fill,
        );
        break;
      case Placement.topLeft:
        final boxW = frameW * 0.42, boxH = frameH * 0.26;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(pad, top + pad, boxW, boxH),
            Radius.circular(boxH / 2),
          ),
          fill,
        );
        break;
      case Placement.topRight:
        final boxW = frameW * 0.30, boxH = frameH * 0.30;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(frameW - pad - boxW, top + pad, boxW, boxH),
            Radius.circular(boxH * 0.3),
          ),
          fill,
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _PlacementPainter old) =>
      old.placement != placement || old.color != color;
}

/// Full-screen, swipeable image viewer. Each page is produced on demand by
/// [loader] (e.g. a high-res render), so you can swipe across all items even
/// before they're ready, and zoom stays sharp. Cached once loaded.
class _FullscreenViewer extends StatefulWidget {
  const _FullscreenViewer({
    required this.initialPage,
    required this.itemCount,
    required this.loader,
    this.placeholders,
  });

  final int initialPage;
  final int itemCount;
  final Future<Uint8List?> Function(int) loader;

  /// Optional already-available images shown immediately (e.g. low-res
  /// previews) while [loader] produces the sharp version.
  final List<Uint8List?>? placeholders;

  @override
  State<_FullscreenViewer> createState() => _FullscreenViewerState();
}

class _FullscreenViewerState extends State<_FullscreenViewer> {
  late final PageController _controller;
  final Map<int, Uint8List> _cache = {};
  final Set<int> _loading = {};

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialPage);
    _load(widget.initialPage);
    _load(widget.initialPage + 1);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load(int i) async {
    if (i < 0 || i >= widget.itemCount) return;
    if (_cache.containsKey(i) || _loading.contains(i)) return;
    _loading.add(i);
    try {
      final bytes = await widget.loader(i);
      if (mounted && bytes != null) setState(() => _cache[i] = bytes);
    } catch (_) {
    } finally {
      _loading.remove(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.itemCount,
            onPageChanged: (i) {
              _load(i);
              _load(i + 1);
              _load(i - 1);
            },
            itemBuilder: (c, i) {
              final hi = _cache[i];
              final ph = (widget.placeholders != null &&
                      i < widget.placeholders!.length)
                  ? widget.placeholders![i]
                  : null;
              final bytes = hi ?? ph;
              if (bytes == null) {
                _load(i);
                return const Center(child: CircularProgressIndicator());
              }
              if (hi == null) _load(i); // upgrade placeholder to sharp version
              // Mouse wheel / pinch zooms; trackpad scroll zooms too.
              return InteractiveViewer(
                maxScale: 6,
                trackpadScrollCausesScale: true,
                child: Center(
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              );
            },
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 36,
                    padding: const EdgeInsets.all(12),
                    tooltip: 'Fechar',
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

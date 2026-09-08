import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models.dart';
import 'preview_worker.dart';
import 'watermark_engine.dart';

/// Style + measurement of a text at a given font size (see `_measureText`).
typedef _TextMeasure = ({
  TextStyle style,
  double strokeW,
  double pad,
  TextPainter measure,
});

/// Size of a laid-out text block plus a function that paints it at an origin.
typedef _TextGeometry = ({
  double w,
  double h,
  double glyphH,
  void Function(Canvas canvas, Offset origin) paint,
});

/// A picture placed on the text's arc, before and/or after the glyphs.
class _EndPic {
  const _EndPic({
    required this.image,
    required this.w,
    required this.h,
    required this.gap,
    required this.left,
    required this.right,
  });
  final ui.Image image;
  final double w;
  final double h;
  final double gap;
  final bool left;
  final bool right;
}

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
  bool _renderingPreview = false; // a preview render loop is in progress
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
  final Map<int, ImageSrc> _textSrc = {}; // rasterized text (raw RGBA), by id
  final Map<int, double> _textRatio = {}; // glyph-box / bitmap height, by id
  Future<void> _textJob = Future.value(); // rasterizations run one at a time
  final Map<int, String> _textSigCache = {}; // look snapshot, for invalidation
  int _previewIndex = 0; // which of the preview photos is shown big

  // ---- Save state: incremental save into ONE album per project ----
  final Set<String> _savedPaths = {}; // photo paths already saved this project
  String? _currentAlbum; // album reused for the whole project
  _ProcessResult? _lastResult; // persistent result banner

  // Preview state. Renders live in a long-lived worker isolate that caches the
  // decoded sources, so a change only composites.
  final PreviewWorker _worker = PreviewWorker();
  // Small downscaled copies used ONLY for the live preview (fast re-renders).
  final Map<String, Uint8List> _previewPhoto = {}; // by photo path
  final Map<int, Uint8List> _previewLogo = {}; // by logo id
  final Map<String, _Preview> _previews = {}; // by photo path
  final Map<String, int> _renderedVersion = {}; // version each render is from
  final Set<String> _previewFailed = {}; // photos that can't be decoded
  int _previewVersion = 0; // bumped whenever the look (logos/texts/sliders) changes
  int _previewToken = 0;
  Timer? _debounce;
  final ScrollController _thumbCtl = ScrollController();
  List<Map<String, dynamic>> _history = []; // past saves, newest first

  // Processing state.
  bool _processing = false;
  bool _cancelRequested = false; // user asked to stop after the current image
  int _done = 0;
  int _total = 0;

  bool get _hasAnyLogo =>
      _bottomLogos.isNotEmpty || _topLeftLogos.isNotEmpty || _cornerLogo != null;

  /// Anything to draw on the photos: a logo or a non-empty text.
  bool get _hasAnyContent => _hasAnyLogo || _texts.any(_textHasContent);

  static bool _textHasContent(TextItem t) =>
      t.text.trim().isNotEmpty || t.imageBytes != null;

  /// Photos selected but not yet saved in this project.
  List<String> get _unsavedPaths =>
      _photoPaths.where((p) => !_savedPaths.contains(p)).toList();

  /// Controls are disabled until at least one photo is added and while a save
  /// is running. After a save everything is usable again: changing the look
  /// then makes the next save write every photo again into a new folder.
  bool get _controlsEnabled => !_processing && _photoPaths.isNotEmpty;
  bool get _canProcess =>
      !_processing && _hasAnyContent && _unsavedPaths.isNotEmpty;
  bool get _allSaved =>
      _photoPaths.isNotEmpty && _hasAnyContent && _unsavedPaths.isEmpty;

  @override
  void initState() {
    super.initState();
    _worker.start();
    _loadProject();
    _getHistory().then((h) {
      if (mounted) setState(() => _history = h);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _worker.dispose();
    _thumbCtl.dispose();
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
    _kickPreview();
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
      if (mounted) setState(() => _importDone = ++done);
      return path;
    }));
    setState(() {
      _photoPaths.addAll(paths);
      _importing = false;
    });
    _kickPreview();
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
    var skipped = 0, added = 0;
    _previewToken++; // stop any running preview loop while the lists change
    _worker.cancelPending();
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
          added++;
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
    if (added > 0) {
      _schedulePreview();
    } else {
      _kickPreview(); // nothing changed; just resume the preview loop
    }
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
    _previewToken++; // stop any running preview loop while the logo changes
    _worker.cancelPending();
    setState(() {
      _cornerLogo = LogoItem(_nextLogoId++, path, x.name, bytes, fp,
          const <String>{}, const <String>{});
      _importing = false;
    });
    _schedulePreview();
  }

  // ---- Preview ----

  /// The look changed (logos, texts or sliders): every photo needs a new
  /// render. The photo on screen is rendered first, the rest in the background.
  void _schedulePreview() {
    _saveProject();
    _previewVersion++;
    if (_currentAlbum != null && !_processing) {
      // The look changed after a save: nothing counts as saved any more, so
      // the next save writes every photo (into a new folder).
      setState(() {
        _savedPaths.clear();
        _currentAlbum = null;
      });
    }
    _kickPreview();
  }

  /// Restarts the render loop WITHOUT invalidating existing renders (photo
  /// added/removed, another photo selected): up-to-date photos are skipped.
  void _kickPreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _recomputePreviews);
  }

  /// Photos in render priority: the selected one first, then its neighbours.
  List<String> _previewOrder() {
    if (_photoPaths.isEmpty) return const [];
    final sel = _previewIndex.clamp(0, _photoPaths.length - 1);
    final order = <String>[_photoPaths[sel]];
    for (var d = 1; d < _photoPaths.length; d++) {
      if (sel + d < _photoPaths.length) order.add(_photoPaths[sel + d]);
      if (sel - d >= 0) order.add(_photoPaths[sel - d]);
    }
    return order;
  }

  Future<void> _recomputePreviews() async {
    final token = ++_previewToken;
    _worker.cancelPending(); // drop renders queued by an abandoned loop
    if (_photoPaths.isEmpty || !_hasAnyContent) {
      setState(() {
        _previews.clear();
        _renderedVersion.clear();
        _renderingPreview = false;
      });
      return;
    }
    setState(() => _renderingPreview = true);
    // Small copies of the logos, once (cached), so renders are cheap.
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

    final version = _previewVersion;
    for (final path in _previewOrder()) {
      if (_renderedVersion[path] == version) continue;
      if (_previewFailed.contains(path)) continue;
      if (!_photoPaths.contains(path)) continue; // removed meanwhile
      try {
        final Uint8List small;
        final cached = _previewPhoto[path];
        if (cached != null) {
          small = cached;
        } else {
          final full = await File(path).readAsBytes();
          if (token != _previewToken) return;
          small = await compute<(Uint8List, int, bool), Uint8List>(
              downscaleImage, (full, 1280, false));
          if (token != _previewToken) return;
          if (!_photoPaths.contains(path)) continue;
          _previewPhoto[path] = small;
        }
        final out = await _worker.render(_previewRequest(path, small));
        if (token != _previewToken) return;
        if (out == null) continue;
        final aspect = await _aspectOf(out);
        if (token != _previewToken || !mounted) return;
        if (!_photoPaths.contains(path)) continue;
        setState(() {
          _previews[path] = _Preview(out, aspect);
          _renderedVersion[path] = version;
        });
      } catch (_) {
        // A photo that can't be read/decoded must not block the others.
        _previewFailed.add(path);
        if (token != _previewToken) return;
      }
    }
    if (mounted && token == _previewToken) {
      setState(() => _renderingPreview = false);
    }
  }

  /// Width/height of an encoded image; throws if it can't be decoded (the
  /// caller treats that as a failed preview).
  Future<double> _aspectOf(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final aspect = image.height == 0 ? 1.0 : image.width / image.height;
      image.dispose();
      return aspect;
    } finally {
      codec.dispose();
    }
  }

  /// Watermark request for the live preview, using the small cached photo and
  /// logo copies (the saved image still uses the full-resolution originals).
  /// Keys are stable so the worker reuses its decoded images.
  WatermarkRequest _previewRequest(String path, Uint8List photoSmall) {
    ImageSrc logo(LogoItem e) {
      final small = _previewLogo[e.id];
      return small != null
          ? ImageSrc('ls:${e.id}', small)
          : ImageSrc('l:${e.id}', e.bytes);
    }
    return WatermarkRequest(
      photo: ImageSrc('ps:$path', photoSmall),
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
      textOverlays: _textOverlays(preview: true),
      quality: 85,
    );
  }

  WatermarkRequest _request(Uint8List photoBytes,
      {int? maxDim, int quality = 95, bool png = false}) {
    ImageSrc logo(LogoItem e) => ImageSrc('l:${e.id}', e.bytes);
    return WatermarkRequest(
      photo: ImageSrc('full', photoBytes),
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

  /// Snapshot of the properties that change the rasterized PNG. Size and
  /// vertical position are applied when compositing, so moving/resizing a text
  /// never forces a re-raster.
  String _textSig(TextItem t) =>
      '${t.text}|${t.fontFamily}|${t.bold}|${t.italic}|${t.color}|'
      '${t.rainbow}|${t.outline}|${t.outlineColor}|${t.outlineWidth}|${t.curve}|'
      '${t.imageSig}|${t.imagePos.index}|${t.imageSize}|${t.imageGap}';

  /// Re-rasterizes any text whose look changed. Runs on the UI thread (canvas
  /// text drawing can't run in an isolate) but is fast — it's only text.
  Future<void> _ensureTextPngs() {
    // Serialized: while a slider is dragged many calls arrive, but each one
    // waits for the previous rasterization and then re-checks the signature,
    // so intermediate looks are skipped instead of piling up.
    final job = _textJob.then((_) => _rasterizeDirty());
    _textJob = job.catchError((_) {});
    return job;
  }

  Future<void> _rasterizeDirty() async {
    for (final t in List<TextItem>.from(_texts)) {
      if (!_textHasContent(t)) continue;
      final sig = _textSig(t);
      if (_textSigCache[t.id] == sig && _textSrc.containsKey(t.id)) continue;
      try {
        final r = await _rasterizeText(t);
        if (!mounted) return;
        if (!_texts.contains(t)) continue; // removed meanwhile: discard
        final key = 't:${t.id}:$sig';
        _textSrc[t.id] =
            ImageSrc(key, r.bytes, rawWidth: r.w, rawHeight: r.h);
        _textRatio[t.id] = r.contentRatio;
        _textSigCache[t.id] = sig;
        // Ship the pixels to the preview worker once; preview requests then
        // reference them by key with an empty payload.
        _worker.putRaw(key, r.w, r.h, r.bytes, group: 't:${t.id}:');
      } catch (_) {
        // Couldn't render this text: drop it (never show a stale look) and
        // keep going with the rest.
        _textSrc.remove(t.id);
        _textRatio.remove(t.id);
        _textSigCache.remove(t.id);
      }
    }
  }

  /// [preview] requests reference the text pixels already pinned in the
  /// worker (empty payload); full renders/saves carry the pixels.
  List<TextOverlay> _textOverlays({bool preview = false}) => [
        for (final t in _texts)
          if (_textHasContent(t) && _textSrc[t.id] != null)
            TextOverlay(
              src: preview
                  ? ImageSrc(_textSrc[t.id]!.key, Uint8List(0),
                      rawWidth: _textSrc[t.id]!.rawWidth,
                      rawHeight: _textSrc[t.id]!.rawHeight)
                  : _textSrc[t.id]!,
              height: t.heightPct / 100,
              top: t.topPct / 100,
              contentRatio: _textRatio[t.id] ?? 1.0,
            ),
      ];

  /// Draws one text into a transparent PNG with Flutter's text engine (system
  /// fonts, outline, rainbow gradient). Rendered big so it stays sharp when
  /// scaled onto full-resolution photos, but capped in width so the pure-Dart
  /// decode in the engine stays cheap and long texts are never clipped.
  Future<({Uint8List bytes, int w, int h, double contentRatio})>
      _rasterizeText(TextItem t) async {
    const maxWidth = 2048.0, maxHeight = 1200.0;
    var fontSize = 256.0;
    var m = _measureText(t, fontSize);
    final totalW = m.measure.width + m.pad * 2;
    final totalH = m.measure.height + m.pad * 2;
    final scale = [maxWidth / totalW, maxHeight / totalH, 1.0]
        .reduce((a, b) => a < b ? a : b);
    if (scale < 1.0) {
      fontSize *= scale;
      m = _measureText(t, fontSize);
    }
    // Optional picture attached to the text (decoded by Flutter: fast).
    ui.Image? pic;
    final picBytes = t.imageBytes;
    if (picBytes != null) {
      try {
        final codec = await ui.instantiateImageCodec(picBytes,
            targetWidth: 1024, allowUpscaling: false);
        pic = (await codec.getNextFrame()).image;
        codec.dispose();
      } catch (_) {
        pic = null;
      }
    }

    final hasText = t.text.trim().isNotEmpty;
    final curved = t.curve.abs() >= 0.5;
    // Curved text is always a single line; straight text may have several.
    final glyphH = curved ? _lineHeight(m) : m.measure.height;
    final picH = pic == null ? 0.0 : glyphH * t.imageSize / 100;
    final picW = pic == null ? 0.0 : picH * pic.width / pic.height;
    final gap = glyphH * t.imageGap / 100;
    final sidePos = t.imagePos == TextImagePos.left ||
        t.imagePos == TextImagePos.right ||
        t.imagePos == TextImagePos.both;

    // On a curve, a picture beside the text rides the arc like a glyph.
    _EndPic? endPic;
    if (pic != null && hasText && curved && sidePos) {
      endPic = _EndPic(
        image: pic,
        w: picW,
        h: picH,
        gap: gap,
        left: t.imagePos != TextImagePos.right,
        right: t.imagePos != TextImagePos.left,
      );
    }
    final geo = curved
        ? _curvedGeometry(t, m, endPic: endPic)
        : _straightGeometry(t, m);

    // Lay out text + picture as ONE block; the engine centers the block.
    var w = geo.w, h = geo.h;
    var textOrigin = Offset.zero;
    final picRects = <Rect>[];
    if (pic != null && !hasText) {
      // Picture only: no phantom empty line around it.
      w = picW;
      h = picH;
      picRects.add(Rect.fromLTWH(0, 0, picW, picH));
    } else if (pic != null && endPic == null) {
      switch (t.imagePos) {
        case TextImagePos.top:
          w = math.max(geo.w, picW);
          h = picH + gap + geo.h;
          picRects.add(Rect.fromLTWH((w - picW) / 2, 0, picW, picH));
          textOrigin = Offset((w - geo.w) / 2, picH + gap);
        case TextImagePos.bottom:
          w = math.max(geo.w, picW);
          h = geo.h + gap + picH;
          textOrigin = Offset((w - geo.w) / 2, 0);
          picRects.add(Rect.fromLTWH((w - picW) / 2, geo.h + gap, picW, picH));
        case TextImagePos.left:
          w = picW + gap + geo.w;
          h = math.max(geo.h, picH);
          picRects.add(Rect.fromLTWH(0, (h - picH) / 2, picW, picH));
          textOrigin = Offset(picW + gap, (h - geo.h) / 2);
        case TextImagePos.right:
          w = geo.w + gap + picW;
          h = math.max(geo.h, picH);
          textOrigin = Offset(0, (h - geo.h) / 2);
          picRects.add(Rect.fromLTWH(geo.w + gap, (h - picH) / 2, picW, picH));
        case TextImagePos.both:
          w = picW + gap + geo.w + gap + picW;
          h = math.max(geo.h, picH);
          picRects.add(Rect.fromLTWH(0, (h - picH) / 2, picW, picH));
          textOrigin = Offset(picW + gap, (h - geo.h) / 2);
          picRects.add(Rect.fromLTWH(w - picW, (h - picH) / 2, picW, picH));
        case TextImagePos.inside:
          // Inside the arc: hanging from the top of an upward curve, resting
          // on the bottom of a downward one; behind the text when straight.
          w = math.max(geo.w, picW);
          double picY;
          if (t.curve > 0.5) {
            picY = geo.glyphH + gap;
          } else if (t.curve < -0.5) {
            picY = geo.h - geo.glyphH - gap - picH;
          } else {
            picY = (geo.h - picH) / 2;
          }
          final shift = picY < 0 ? -picY : 0.0;
          h = math.max(geo.h, picY + picH) + shift;
          picRects.add(Rect.fromLTWH((w - picW) / 2, picY + shift, picW, picH));
          textOrigin = Offset((w - geo.w) / 2, shift);
      }
    }

    // Keep the whole block within a sane bitmap (a big picture next to the
    // text can exceed it): draw everything scaled down instead of clipping.
    const maxBlockW = 2560.0, maxBlockH = 1600.0;
    final s = [maxBlockW / w, maxBlockH / h, 1.0].reduce((a, b) => a < b ? a : b);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (s < 1.0) canvas.scale(s);
    if (pic != null) {
      for (final r in picRects) {
        canvas.drawImageRect(
          pic,
          Rect.fromLTWH(0, 0, pic.width.toDouble(), pic.height.toDouble()),
          r,
          Paint()..filterQuality = FilterQuality.high,
        );
      }
    }
    if (hasText) geo.paint(canvas, textOrigin);
    final picture = recorder.endRecording();
    final pngW = (w * s).ceil().clamp(1, 8192);
    final pngH = (h * s).ceil().clamp(1, 8192);
    final image = await picture.toImage(pngW, pngH);
    picture.dispose();
    pic?.dispose();
    // Raw pixels: no PNG encode here and no pure-Dart decode in the renderer.
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    if (data == null) throw StateError('raster readback failed');
    return (
      bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      w: pngW,
      h: pngH,
      contentRatio: geo.glyphH * s / pngH,
    );
  }

  /// Straight text (several lines allowed, centered).
  _TextGeometry _straightGeometry(TextItem t, _TextMeasure m) {
    final textW = m.measure.width, textH = m.measure.height, pad = m.pad;
    TextPainter painterWith(Paint foreground) => TextPainter(
          text: TextSpan(
              text: t.text, style: m.style.copyWith(foreground: foreground)),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
        )..layout(minWidth: textW);
    return (
      w: textW + pad * 2,
      h: textH + pad * 2,
      glyphH: textH,
      paint: (Canvas canvas, Offset origin) {
        final o = origin + Offset(pad, pad);
        if (t.outline) {
          painterWith(_outlinePaint(t, m.strokeW)).paint(canvas, o);
        }
        final fill = Paint();
        if (t.rainbow) {
          fill.shader = ui.Gradient.linear(Offset(o.dx, 0),
              Offset(o.dx + math.max(textW, 1.0), 0), kRainbow, kRainbowStops);
        } else {
          fill.color = Color(t.color);
        }
        painterWith(fill).paint(canvas, o);
      },
    );
  }

  static const List<Color> kRainbow = [
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFF8E24AA),
  ];
  static const List<double> kRainbowStops = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0];

  Paint _outlinePaint(TextItem t, double strokeW) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeW
    ..strokeJoin = StrokeJoin.round
    ..color = Color(t.outlineColor);

  /// Color of the rainbow at position [u] (0..1).
  Color _rainbowAt(double u) {
    final x = u.clamp(0.0, 1.0);
    for (var i = 0; i < kRainbowStops.length - 1; i++) {
      if (x <= kRainbowStops[i + 1]) {
        final span = kRainbowStops[i + 1] - kRainbowStops[i];
        final f = span <= 0 ? 0.0 : (x - kRainbowStops[i]) / span;
        return Color.lerp(kRainbow[i], kRainbow[i + 1], f)!;
      }
    }
    return kRainbow.last;
  }

  /// Lays out [t] glyph by glyph along a circular arc of [TextItem.curve]
  /// degrees (positive = arc up, like a rainbow; negative = arc down). With
  /// [endPic] the picture is placed on the arc before and/or after the text,
  /// rotated like the glyphs.
  _TextGeometry _curvedGeometry(TextItem t, _TextMeasure m, {_EndPic? endPic}) {
    final chars = [
      for (final r in t.text.replaceAll('\n', ' ').runes) String.fromCharCode(r)
    ];
    final painters = [
      for (final c in chars)
        TextPainter(
          text: TextSpan(text: c, style: m.style),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    final lineH = _lineHeight(m);
    // Items along the arc: [picture, gap,] glyphs... [, gap, picture].
    // kind: 0 = glyph (index into chars), 1 = picture, 2 = spacer.
    final kinds = <int>[];
    final widths = <double>[];
    final heights = <double>[];
    final glyphIndex = <int>[];
    void add(int kind, double w, double h, [int gi = -1]) {
      kinds.add(kind);
      widths.add(w);
      heights.add(h);
      glyphIndex.add(gi);
    }

    if (endPic != null && endPic.left) {
      add(1, endPic.w, endPic.h);
      add(2, endPic.gap, 1);
    }
    for (var i = 0; i < chars.length; i++) {
      add(0, painters[i].width, lineH, i);
    }
    if (endPic != null && endPic.right) {
      add(2, endPic.gap, 1);
      add(1, endPic.w, endPic.h);
    }
    final total = widths.fold(0.0, (a, b) => a + b);
    final theta = t.curve.abs().clamp(0.5, 355.0) * math.pi / 180;
    final s = t.curve > 0 ? 1.0 : -1.0;
    final radius = math.max(total, 1.0) / theta;

    // Glyph centers sit on a circle around the origin; each glyph is rotated
    // to follow the tangent.
    final centers = <Offset>[];
    final angles = <double>[];
    var acc = 0.0;
    for (final w in widths) {
      final phi = -theta / 2 + (acc + w / 2) / radius;
      acc += w;
      angles.add(s * phi);
      centers.add(Offset(radius * math.sin(phi), -s * radius * math.cos(phi)));
    }

    // Bounding box of the rotated boxes.
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (var i = 0; i < kinds.length; i++) {
      if (kinds[i] == 2) continue;
      final c = centers[i];
      final rot = angles[i];
      final hw = widths[i] / 2, hh = heights[i] / 2;
      for (final k in [
        Offset(-hw, -hh),
        Offset(hw, -hh),
        Offset(hw, hh),
        Offset(-hw, hh)
      ]) {
        final x = c.dx + k.dx * math.cos(rot) - k.dy * math.sin(rot);
        final y = c.dy + k.dx * math.sin(rot) + k.dy * math.cos(rot);
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
      }
    }
    if (minX == double.infinity) {
      minX = minY = 0;
      maxX = maxY = 1;
    }
    final pad = m.pad;
    final n = chars.length;

    return (
      w: maxX - minX + pad * 2,
      h: maxY - minY + pad * 2,
      glyphH: lineH,
      paint: (Canvas canvas, Offset origin) {
        final o = origin + Offset(pad - minX, pad - minY);
        void pass(Paint Function(int gi) paintFor) {
          for (var i = 0; i < kinds.length; i++) {
            if (kinds[i] != 0) continue;
            final gi = glyphIndex[i];
            final p = TextPainter(
              text: TextSpan(
                  text: chars[gi],
                  style: m.style.copyWith(foreground: paintFor(gi))),
              textDirection: TextDirection.ltr,
            )..layout();
            canvas.save();
            canvas.translate(o.dx + centers[i].dx, o.dy + centers[i].dy);
            canvas.rotate(angles[i]);
            p.paint(canvas, Offset(-p.width / 2, -p.height / 2));
            canvas.restore();
          }
        }

        // Pictures on the arc (rotated like the glyphs).
        if (endPic != null) {
          final src = Rect.fromLTWH(0, 0, endPic.image.width.toDouble(),
              endPic.image.height.toDouble());
          for (var i = 0; i < kinds.length; i++) {
            if (kinds[i] != 1) continue;
            canvas.save();
            canvas.translate(o.dx + centers[i].dx, o.dy + centers[i].dy);
            canvas.rotate(angles[i]);
            canvas.drawImageRect(
              endPic.image,
              src,
              Rect.fromCenter(
                  center: Offset.zero, width: endPic.w, height: endPic.h),
              Paint()..filterQuality = FilterQuality.high,
            );
            canvas.restore();
          }
        }

        if (t.outline) pass((_) => _outlinePaint(t, m.strokeW));
        pass((gi) => Paint()
          ..color = t.rainbow
              ? _rainbowAt(n <= 1 ? 0.5 : gi / (n - 1))
              : Color(t.color));
      },
    );
  }

  /// Height of one text line in [m]'s style (same for every glyph).
  double _lineHeight(_TextMeasure m) => (TextPainter(
        text: TextSpan(text: 'Ag', style: m.style),
        textDirection: TextDirection.ltr,
      )..layout())
          .height;

  /// Text style + layout for [t] at [fontSize]. [pad] leaves room for the
  /// outline stroke and for glyphs that overhang (italics, swashes).
  _TextMeasure _measureText(TextItem t, double fontSize) {
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
        final bytes = await File(next).readAsBytes();
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
    _history = await _getHistory();
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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI ----

  static const double _sidebarWidth = 430;

  /// Below this width the page keeps its size and scrolls sideways instead of
  /// squeezing the text into single letters.
  static const double _minPageWidth = 1000;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, box) {
          final page = _page();
          if (box.maxWidth >= _minPageWidth) return page;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _minPageWidth,
              height: box.maxHeight,
              child: page,
            ),
          );
        },
      ),
    );
  }

  Widget _page() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
        children: [
          _header(),
          if (_importing) const LinearProgressIndicator(minHeight: 3),
          if (_checkingLogos) ...[
            LinearProgressIndicator(
              minHeight: 3,
              value: _checkTotal > 0 ? _checkDone / _checkTotal : null,
            ),
            Container(
              width: double.infinity,
              color: scheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text('Verificando logo $_checkDone de $_checkTotal…',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
          Expanded(
            // Settings on the left, big preview on the right.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: _sidebarWidth, child: _settingsPanel()),
                VerticalDivider(
                    width: 1, thickness: 1, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: _previewPane()),
                      _actionBar(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
    );
  }

  Widget _header() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          ClipOval(
            child: Image.asset('assets/appbar_logo.png',
                width: 26, height: 26, fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          const Text(
            'JCV Watermarker',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.2),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: (!_processing &&
                    (_photoPaths.isNotEmpty || _savedPaths.isNotEmpty))
                ? _confirmNewProject
                : null,
            icon: const Icon(Icons.add_box_outlined, size: 18),
            label: const Text('Novo projeto'),
          ),
          const SizedBox(width: 4),
          MenuAnchor(
            alignmentOffset: const Offset(0, 4),
            style: const MenuStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
            ),
            menuChildren: _history.isEmpty
                ? [
                    const MenuItemButton(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text('Nenhum salvamento ainda.'),
                      ),
                    ),
                  ]
                : [
                    for (var i = 0; i < _history.length && i < 30; i++)
                      MenuItemButton(
                        onPressed: () {},
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_history[i]['album'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              Text(
                                '${_history[i]['saved']} foto(s) · '
                                '${_fmtDate(_history[i]['time'] as int)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
            builder: (context, controller, child) => TextButton.icon(
              onPressed: _processing
                  ? null
                  : () =>
                      controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.history, size: 18),
              label: const Text('Histórico'),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Build ${const String.fromEnvironment('APP_BUILD', defaultValue: 'dev')}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).disabledColor),
          ),
        ],
      ),
    );
  }

  // ---- Left panel (settings) ----

  Widget _settingsPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (_lastResult != null) _resultBanner(),
          if (_currentAlbum != null && !_processing) _lockedBanner(),
          _photosSection(),
          _logoSection(
            number: 2,
            title: 'Logos da base',
            placement: Placement.bottom,
            items: _bottomLogos,
            hint: 'Fileira na base, da esquerda para a direita ou centralizada. '
                'Tamanho, espaço, opacidade e distância da esquerda valem para '
                'as duas fileiras.',
            onAdd: () => _pickLogos(_bottomLogos),
            sliders: [
              _alignmentChooser(),
              _slider('Tamanho (todas)', _logoSize, 5, 30,
                  (v) => setState(() => _logoSize = v)),
              _slider('Espaço entre as logos (todas)', _logoSpacing, 0, 10,
                  (v) => setState(() => _logoSpacing = v)),
              if (!_centered)
                _slider('Distância da borda esquerda (todas)', _leftMargin, 0,
                    15, (v) => setState(() => _leftMargin = v)),
              _slider('Opacidade (todas)', _logoOpacity, 0, 100,
                  (v) => setState(() => _logoOpacity = v)),
              _slider('Distância da borda inferior', _bottomMargin, 0, 15,
                  (v) => setState(() => _bottomMargin = v)),
            ],
          ),
          _logoSection(
            number: 3,
            title: 'Logos do canto superior esquerdo',
            placement: Placement.topLeft,
            items: _topLeftLogos,
            hint: 'Fileira no topo, sempre da esquerda para a direita.',
            onAdd: () => _pickLogos(_topLeftLogos),
            sliders: [
              _slider('Tamanho (todas)', _logoSize, 5, 30,
                  (v) => setState(() => _logoSize = v)),
              _slider('Espaço entre as logos (todas)', _logoSpacing, 0, 10,
                  (v) => setState(() => _logoSpacing = v)),
              _slider('Distância da borda esquerda (todas)', _leftMargin, 0,
                  15, (v) => setState(() => _leftMargin = v)),
              _slider('Opacidade (todas)', _logoOpacity, 0, 100,
                  (v) => setState(() => _logoOpacity = v)),
              _slider('Distância da borda superior', _topMargin, 0, 15,
                  (v) => setState(() => _topMargin = v)),
            ],
          ),
          _cornerSection(),
          _textsSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _photosSection() {
    final small = Theme.of(context).textTheme.bodySmall;
    return _Section(
      number: 1,
      title: 'Fotos',
      icon: const Icon(Icons.photo_library_outlined, size: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: _processing ? null : _pickPhotos,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('Adicionar fotos'),
              ),
              const SizedBox(width: 12),
              if (_importing)
                Text(
                    _importTotal > 0
                        ? 'Carregando… $_importDone de $_importTotal'
                        : 'Carregando…',
                    style: small)
              else if (_photoPaths.isNotEmpty)
                Text('${_photoPaths.length} foto(s)', style: small),
            ],
          ),
          if (_photoPaths.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 60,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photoPaths.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) => _thumb(
                  size: 60,
                  enabled: _controlsEnabled,
                  child: Image.file(File(_photoPaths[i]),
                      fit: BoxFit.cover, cacheWidth: 160),
                  onRemove: () {
                    final path = _photoPaths[i];
                    _previewToken++; // discard any in-flight render of it
                    setState(() {
                      _photoPaths.removeAt(i);
                      _previews.remove(path);
                      _renderedVersion.remove(path);
                      _previewFailed.remove(path);
                    });
                    _previewPhoto.remove(path);
                    File(path).delete().ignore();
                    _kickPreview();
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _logoSection({
    required int number,
    required String title,
    required Placement placement,
    required List<LogoItem> items,
    required String hint,
    required VoidCallback onAdd,
    required List<Widget> sliders,
  }) {
    final small = Theme.of(context).textTheme.bodySmall;
    return _Section(
      number: number,
      title: title,
      icon: _PlacementIcon(placement),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                onPressed:
                    (_photoPaths.isEmpty || !_controlsEnabled) ? null : onAdd,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Adicionar logos'),
              ),
              const SizedBox(width: 12),
              if (items.isNotEmpty)
                Text('${items.length} logo(s)', style: small),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _photoPaths.isEmpty
                ? 'Adicione as fotos primeiro; depois envie as logos.'
                : hint,
            style: small,
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
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
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  minLeadingWidth: 36,
                  leading: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _processing
                        ? null
                        : () => _openImagesFullscreen(
                            items.map((e) => e.bytes).toList(), i),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 36,
                        height: 36,
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: Image.memory(item.bytes, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                  title: Text('${i + 1}. ${item.sourceKey}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Remover',
                        onPressed: !_controlsEnabled
                            ? null
                            : () {
                                setState(() => items.removeAt(i));
                                _schedulePreview();
                              },
                      ),
                      if (_controlsEnabled && items.length > 1)
                        ReorderableDragStartListener(
                          index: i,
                          child: const MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(Icons.drag_handle, size: 20),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            if (items.length > 1)
              Text('Arraste pela alça para reordenar.', style: small),
            ...sliders,
          ],
        ],
      ),
    );
  }

  Widget _cornerSection() {
    final small = Theme.of(context).textTheme.bodySmall;
    return _Section(
      number: 4,
      title: 'Logo principal (canto superior direito)',
      icon: const _PlacementIcon(Placement.topRight),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_cornerLogo != null) ...[
                _thumb(
                  size: 52,
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
                const SizedBox(width: 10),
              ],
              OutlinedButton.icon(
                onPressed: (_photoPaths.isEmpty || !_controlsEnabled)
                    ? null
                    : _pickCornerLogo,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(_cornerLogo == null ? 'Adicionar' : 'Trocar'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Uma única logo no canto superior direito.', style: small),
          if (_cornerLogo != null) ...[
            _slider('Tamanho', _cornerHeight, 5, 40,
                (v) => setState(() => _cornerHeight = v)),
            _slider('Distância do canto', _cornerMargin, 0, 15,
                (v) => setState(() => _cornerMargin = v)),
          ],
        ],
      ),
    );
  }

  Widget _textsSection() {
    final small = Theme.of(context).textTheme.bodySmall;
    return _Section(
      number: 5,
      title: 'Textos',
      icon: const Icon(Icons.text_fields, size: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: (_photoPaths.isEmpty || !_controlsEnabled)
                    ? null
                    : _addText,
                icon: const Icon(Icons.title, size: 18),
                label: const Text('Adicionar texto'),
              ),
              const SizedBox(width: 12),
              if (_texts.isNotEmpty)
                Text('${_texts.length} texto(s)', style: small),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _photoPaths.isEmpty
                ? 'Adicione as fotos primeiro; depois crie os textos.'
                : 'Sempre centralizado na horizontal. Fonte do computador, '
                    'qualquer cor, contorno, arco-íris, curvatura e uma '
                    'imagem junto ao texto.',
            style: small,
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
      _textSrc.remove(t.id);
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

    Widget toggle(String label, bool on, ValueChanged<bool> set) => FilterChip(
          label: Text(label),
          selected: on,
          onSelected: !_controlsEnabled ? null : (s) => update(() => set(s)),
        );

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: ValueKey('text_${t.id}'),
            initialValue: t.text,
            enabled: _controlsEnabled,
            maxLines: null,
            decoration: const InputDecoration(labelText: 'Texto'),
            onChanged: (v) {
              t.text = v;
              _schedulePreview();
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Fonte (do computador)',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 2),
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
                              if (v != null && v != t.fontFamily) {
                                update(() => t.fontFamily = v);
                              }
                            },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Remover texto',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: !_controlsEnabled ? null : () => _removeText(t),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              toggle('Negrito', t.bold, (s) => t.bold = s),
              toggle('Itálico', t.italic, (s) => t.italic = s),
              toggle('Contorno', t.outline, (s) => t.outline = s),
              toggle('Arco-íris', t.rainbow, (s) => t.rainbow = s),
            ],
          ),
          const SizedBox(height: 10),
          Text('Imagem junto ao texto',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            children: [
              if (t.imageBytes != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    width: 36,
                    height: 36,
                    color: scheme.surfaceContainerHighest,
                    child: Image.memory(t.imageBytes!, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              OutlinedButton.icon(
                onPressed:
                    !_controlsEnabled ? null : () => _pickTextImage(t),
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(
                    t.imageBytes == null ? 'Adicionar imagem' : 'Trocar'),
              ),
              if (t.imageBytes != null)
                IconButton(
                  tooltip: 'Remover imagem',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: !_controlsEnabled
                      ? null
                      : () => update(() {
                            t.imageBytes = null;
                            t.imageName = null;
                            t.imageSig = 0;
                          }),
                ),
            ],
          ),
          if (t.imageBytes != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final pos in TextImagePos.values)
                  ChoiceChip(
                    label: Text(_imagePosLabel(pos)),
                    selected: t.imagePos == pos,
                    onSelected: !_controlsEnabled
                        ? null
                        : (_) {
                            if (pos != t.imagePos) {
                              update(() => t.imagePos = pos);
                            }
                          },
                  ),
              ],
            ),
            _slider('Tamanho da imagem (% da altura do texto)', t.imageSize,
                20, 400, (v) => setState(() => t.imageSize = v)),
            _slider('Espaço entre imagem e texto (% da altura do texto)',
                t.imageGap, 0, 100, (v) => setState(() => t.imageGap = v)),
          ],
          if (!t.rainbow) ...[
            const SizedBox(height: 8),
            _colorField(
              '${t.id}:fill',
              'Cor do texto',
              t.color,
              (c) {
                _hoverBackup.remove('${t.id}:fill');
                update(() => t.color = c);
              },
              (c) => _hover('${t.id}:fill', c, () => t.color,
                  (v) => t.color = v),
            ),
          ],
          if (t.outline) ...[
            const SizedBox(height: 8),
            _colorField(
              '${t.id}:outline',
              'Cor do contorno',
              t.outlineColor,
              (c) {
                _hoverBackup.remove('${t.id}:outline');
                update(() => t.outlineColor = c);
              },
              (c) => _hover('${t.id}:outline', c, () => t.outlineColor,
                  (v) => t.outlineColor = v),
            ),
            _slider('Espessura do contorno', t.outlineWidth, 2, 20,
                (v) => setState(() => t.outlineWidth = v)),
          ],
          _slider('Tamanho do texto', t.heightPct, 2, 60,
              (v) => setState(() => t.heightPct = v)),
          _slider('Altura na foto (0 = topo, 100 = base)', t.topPct, 0, 100,
              (v) => setState(() => t.topPct = v)),
          _slider('Curvatura (− para baixo, + para cima)', t.curve, -180, 180,
              (v) => setState(() => t.curve = v),
              unit: '°'),
        ],
      ),
    );
  }

  String _imagePosLabel(TextImagePos pos) => switch (pos) {
        TextImagePos.top => 'Em cima',
        TextImagePos.bottom => 'Embaixo',
        TextImagePos.left => 'À esquerda',
        TextImagePos.right => 'À direita',
        TextImagePos.both => 'Dos dois lados',
        TextImagePos.inside => 'Dentro da curva',
      };

  Future<void> _pickTextImage(TextItem t) async {
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    setState(() {
      t.imageBytes = bytes;
      t.imageName = x.name;
      t.imageSig = _imageSig(bytes);
    });
    _schedulePreview();
  }

  // ---- Colors ----

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

  static String _hex(int argb) =>
      (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  String? _openColor; // which color field has its panel open ("id:fill")
  final Map<String, int> _hoverBackup = {}; // color before a hover preview

  /// Re-renders the previews without touching the saved state (used for the
  /// temporary hover preview, which is not a real change).
  void _previewOnly() {
    _previewVersion++;
    _kickPreview();
  }

  /// Hover preview: while the mouse is over a swatch the photo shows that
  /// color; leaving restores the real one. [c] null = mouse left.
  void _hover(String key, int? c, int Function() get, void Function(int) set) {
    if (c == null) {
      final back = _hoverBackup.remove(key);
      if (back != null && get() != back) {
        setState(() => set(back));
        _previewOnly();
      }
    } else {
      _hoverBackup.putIfAbsent(key, get);
      if (get() != c) {
        setState(() => set(c));
        _previewOnly();
      }
    }
  }

  /// Label + quick swatches (hover to preview) + the current hex value, which
  /// opens an inline panel with a hex field and hue/saturation/brightness
  /// sliders that apply live. No dialog, nothing covers the preview.
  Widget _colorField(String key, String label, int selected,
      ValueChanged<int> onPick, ValueChanged<int?> onHover) {
    final scheme = Theme.of(context).colorScheme;
    final open = _openColor == key;
    // The model holds the hovered color during a hover preview; the REAL
    // choice is the backup, so clicking the hovered swatch still applies it.
    final real = _hoverBackup[key] ?? selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final c in _swatches)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: !_controlsEnabled ? null : (_) => onHover(c),
                onExit: !_controlsEnabled ? null : (_) => onHover(null),
                child: GestureDetector(
                  onTap: (!_controlsEnabled || c == real)
                      ? null
                      : () => onPick(c),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Color(c),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: real == c ? scheme.primary : scheme.outline,
                        width: real == c ? 2 : 1,
                      ),
                    ),
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: !_controlsEnabled
                  ? null
                  : () => setState(() => _openColor = open ? null : key),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 28),
                  side: BorderSide(
                      color: open ? scheme.primary : scheme.outline)),
              icon: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Color(selected),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: scheme.outline),
                ),
              ),
              label: Text('#${_hex(selected)} ${open ? '▴' : '▾'}'),
            ),
          ],
        ),
        if (open) ...[
          const SizedBox(height: 6),
          _ColorPanel(
            key: ValueKey('panel:$key'),
            color: selected,
            enabled: _controlsEnabled,
            onChanged: onPick,
          ),
        ],
      ],
    );
  }

  // ---- Right pane (preview) ----

  void _selectPreview(int i) {
    setState(() => _previewIndex = i);
    _kickPreview();
    // Keep the selected thumbnail in view.
    if (_thumbCtl.hasClients) {
      final target = (i * 68.0 - _thumbCtl.position.viewportDimension / 2 + 30)
          .clamp(0.0, _thumbCtl.position.maxScrollExtent);
      _thumbCtl.animateTo(target,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  Widget _previewPane() {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final paths = _photoPaths;
    if (paths.isEmpty) {
      return Container(
        color: scheme.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, size: 56, color: scheme.outline),
              const SizedBox(height: 10),
              Text('Adicione fotos para ver a pré-visualização.',
                  style: TextStyle(color: scheme.outline)),
            ],
          ),
        ),
      );
    }
    final n = paths.length;
    final idx = _previewIndex.clamp(0, n - 1);
    final path = paths[idx];
    final render = _hasAnyContent ? _previews[path] : null;
    final stale = render != null && _renderedVersion[path] != _previewVersion;
    final rendering = _hasAnyContent && (render == null || stale);

    Widget picture;
    if (render != null) {
      picture = AspectRatio(
        aspectRatio: render.aspect,
        child: Container(
          decoration:
              BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
          child: Image.memory(render.bytes,
              fit: BoxFit.contain, gaplessPlayback: true),
        ),
      );
    } else {
      picture = Image.file(File(path),
          fit: BoxFit.contain, cacheWidth: 1600, gaplessPlayback: true);
    }

    return Container(
      color: scheme.surface,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Center(
                      child: MouseRegion(
                        cursor: _processing
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.zoomIn,
                        child: GestureDetector(
                          onTap: _processing ? null : () => _openFullscreen(idx),
                          child: picture,
                        ),
                      ),
                    ),
                  ),
                  if (rendering)
                    Positioned(
                        top: 8,
                        left: 8,
                        child: _badge(render == null
                            ? 'Gerando pré-visualização…'
                            : 'Atualizando…')),
                  if (!_hasAnyContent)
                    Positioned(
                        top: 8,
                        left: 8,
                        child: _badge('Foto original — adicione logos ou textos')),
                  Positioned(top: 8, right: 8, child: _badge('${idx + 1} / $n')),
                  if (n > 1) ...[
                    Positioned(
                      left: 4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _navButton(Icons.chevron_left,
                            idx > 0 ? () => _selectPreview(idx - 1) : null),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _navButton(Icons.chevron_right,
                            idx < n - 1 ? () => _selectPreview(idx + 1) : null),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(
            height: 72,
            child: ListView.builder(
              controller: _thumbCtl,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              itemCount: n,
              itemBuilder: (context, i) {
                final sel = i == idx;
                final r = _hasAnyContent ? _previews[paths[i]] : null;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _selectPreview(i),
                    child: Container(
                      width: 60,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: sel ? scheme.primary : scheme.outlineVariant,
                          width: sel ? 2 : 1,
                        ),
                      ),
                      child: r != null
                          ? Image.memory(r.bytes,
                              fit: BoxFit.cover, gaplessPlayback: true)
                          : Image.file(File(paths[i]),
                              fit: BoxFit.cover, cacheWidth: 200),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Clique na imagem para tela cheia (roda do mouse dá zoom). '
              'Fotos ainda não atualizadas mostram a versão anterior.',
              style: small,
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 11.5)),
      );

  Widget _navButton(IconData icon, VoidCallback? onPressed) => Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: IconButton(
          icon: Icon(icon, color: Colors.white),
          onPressed: onPressed,
        ),
      );

  // ---- Bottom bar (save / progress) ----

  Widget _actionBar() {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    Widget content;
    if (_processing) {
      final progress = _total == 0 ? 0.0 : _done / _total;
      content = Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Salvando $_done de $_total…',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress, minHeight: 6),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            // Finishes the current image, then stops and restores the
            // pre-save state. Disabled (shows "Cancelando…") once clicked.
            onPressed: _cancelRequested
                ? null
                : () => setState(() => _cancelRequested = true),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: Text(_cancelRequested ? 'Cancelando…' : 'Cancelar'),
          ),
        ],
      );
    } else if (_allSaved && _currentAlbum != null) {
      content = Row(
        children: [
          Expanded(
            child: Text(
              'Tudo salvo na pasta “$_currentAlbum”. Fotos novas vão para a '
              'mesma pasta; use “Novo projeto” para começar do zero.',
              style: small,
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: _pickPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text('Adicionar mais fotos'),
          ),
        ],
      );
    } else {
      final firstSave = _currentAlbum == null;
      content = Row(
        children: [
          Expanded(
            child: Text(
              firstSave
                  ? 'As imagens são salvas em Imagens\\JCV Watermarker, numa '
                      'pasta nomeada pela data/hora.'
                  : 'As novas fotos vão para a mesma pasta “$_currentAlbum”.',
              style: small,
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            onPressed: _canProcess ? _saveAll : null,
            style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: Text(firstSave ? 'Aplicar e salvar tudo' : 'Salvar novas fotos'),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: content,
    );
  }

  // ---- Fullscreen ----

  void _openFullscreen(int index) {
    // Show ALL preview photos (so you can move to ones not rendered yet) and
    // render each at high resolution on demand, so zoom stays sharp.
    final paths = List<String>.of(_photoPaths);
    if (paths.isEmpty) return;
    final placeholders = [for (final p in paths) _previews[p]?.bytes];
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
  /// so logos and text stay sharp when zoomed in the viewer.
  Future<Uint8List?> _renderFull(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      await _ensureTextPngs();
      return await compute(renderWatermark, _request(bytes, quality: 95));
    } catch (_) {
      return null;
    }
  }

  /// Opens any list of image bytes (e.g. logos) in the zoomable viewer.
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

  // ---- Banners / project ----

  Widget _resultBanner() {
    final r = _lastResult!;
    final ok = r.failed == 0;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: ok ? scheme.secondaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    ok
                        ? '${r.saved} foto(s) salva(s)'
                        : '${r.saved} salva(s), ${r.failed} falharam',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('Imagens\\JCV Watermarker\\${r.album}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dispensar',
            onPressed: () => setState(() => _lastResult = null),
          ),
        ],
      ),
    );
  }

  /// Shown once a project has been saved and nothing changed since.
  Widget _lockedBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Projeto salvo na pasta “$_currentAlbum”. Fotos novas vão para a '
              'mesma pasta. Se você mudar logos, textos ou ajustes, o próximo '
              'salvamento grava todas as fotos numa pasta nova.',
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
      _previews.clear();
      _renderedVersion.clear();
      _previewFailed.clear();
      _previewIndex = 0;
      _renderingPreview = false;
      _importing = false;
      _checkingLogos = false;
      _cancelRequested = false;
      _previewPhoto.clear();
      _previewLogo.clear();
      _texts.clear();
      _textSrc.clear();
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
    _worker.clearCache();
    await _installDefaultCorner();
    await _saveProject();
  }

  // ---- Small controls ----

  Widget _alignmentChooser() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Text('Alinhamento', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Esquerda → direita')),
              ButtonSegment(value: true, label: Text('Centralizado')),
            ],
            selected: {_centered},
            showSelectedIcon: false,
            onSelectionChanged: !_controlsEnabled
                ? null
                : (s) {
                    setState(() => _centered = s.first);
                    _schedulePreview();
                  },
          ),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged,
      {String unit = '%'}) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: small)),
              _NumberField(
                value: value,
                min: min,
                max: max,
                unit: unit,
                enabled: _controlsEnabled,
                onSubmitted: (v) {
                  onChanged(v);
                  _schedulePreview();
                },
              ),
            ],
          ),
          SizedBox(
            height: 26,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: !_controlsEnabled
                  ? null
                  : (v) {
                      onChanged(v);
                      _schedulePreview();
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb({
    required Widget child,
    required VoidCallback onRemove,
    VoidCallback? onTap,
    bool enabled = true,
    double size = 60,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: size,
                height: size,
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
                      const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Inline color editor: hex code + hue / saturation / brightness sliders.
/// Every change is applied immediately (live preview on the photo).
class _ColorPanel extends StatefulWidget {
  const _ColorPanel({
    super.key,
    required this.color,
    required this.enabled,
    required this.onChanged,
  });

  final int color;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  State<_ColorPanel> createState() => _ColorPanelState();
}

class _ColorPanelState extends State<_ColorPanel> {
  late HSVColor _hsv = HSVColor.fromColor(Color(widget.color));
  late final TextEditingController _hex =
      TextEditingController(text: _fmt(widget.color));
  final FocusNode _hexFocus = FocusNode();

  static String _fmt(int argb) =>
      (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  @override
  void didUpdateWidget(_ColorPanel old) {
    super.didUpdateWidget(old);
    // Follow the value when it was changed elsewhere (swatch, hover).
    if (widget.color != _hsv.toColor().toARGB32()) {
      _hsv = HSVColor.fromColor(Color(widget.color));
      if (!_hexFocus.hasFocus) _hex.text = _fmt(widget.color);
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  void _apply(HSVColor v) {
    setState(() {
      _hsv = v;
      if (!_hexFocus.hasFocus) _hex.text = _fmt(v.toColor().toARGB32());
    });
    widget.onChanged(v.toColor().toARGB32());
  }

  void _svAt(Offset p, Size size) {
    final sat = (p.dx / size.width).clamp(0.0, 1.0);
    final val = 1 - (p.dy / size.height).clamp(0.0, 1.0);
    _apply(_hsv.withSaturation(sat).withValue(val));
  }

  void _hueAt(Offset p, double width) {
    _apply(_hsv.withHue((p.dx / width).clamp(0.0, 1.0) * 360));
  }

  Widget _handle() => Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _hsv.toColor();
    final pure = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    const squareH = 160.0, barH = 14.0;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          // Saturation (left→right) × brightness (bottom→top) square.
          LayoutBuilder(
            builder: (context, cons) {
              final size = Size(cons.maxWidth, squareH);
              return IgnorePointer(
                ignoring: !widget.enabled,
                child: GestureDetector(
                  // Vertical + horizontal recognizers (not pan) so the drag is
                  // ours and the sidebar list doesn't scroll instead.
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _svAt(d.localPosition, size),
                  onVerticalDragStart: (d) => _svAt(d.localPosition, size),
                  onVerticalDragUpdate: (d) => _svAt(d.localPosition, size),
                  onHorizontalDragStart: (d) => _svAt(d.localPosition, size),
                  onHorizontalDragUpdate: (d) => _svAt(d.localPosition, size),
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              gradient: LinearGradient(
                                  colors: [Colors.white, pure]),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Colors.black],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: _hsv.saturation * size.width - 8,
                          top: (1 - _hsv.value) * size.height - 8,
                          child: _handle(),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          // Hue bar.
          LayoutBuilder(
            builder: (context, cons) {
              final w = cons.maxWidth;
              return IgnorePointer(
                ignoring: !widget.enabled,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _hueAt(d.localPosition, w),
                  onVerticalDragStart: (d) => _hueAt(d.localPosition, w),
                  onVerticalDragUpdate: (d) => _hueAt(d.localPosition, w),
                  onHorizontalDragStart: (d) => _hueAt(d.localPosition, w),
                  onHorizontalDragUpdate: (d) => _hueAt(d.localPosition, w),
                  child: SizedBox(
                    width: w,
                    height: 20,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          top: (20 - barH) / 2,
                          child: Container(
                            height: barH,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(barH / 2),
                              gradient: LinearGradient(colors: [
                                for (var h = 0; h <= 360; h += 60)
                                  HSVColor.fromAHSV(1, h.toDouble(), 1, 1)
                                      .toColor(),
                              ]),
                            ),
                          ),
                        ),
                        Positioned(
                          left: (_hsv.hue / 360) * w - 8,
                          top: 2,
                          child: _handle(),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: scheme.outline),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                height: 30,
                child: TextField(
                  controller: _hex,
                  focusNode: _hexFocus,
                  enabled: widget.enabled,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    prefixText: '#',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  onChanged: (v) {
                    final clean = v.replaceAll('#', '').trim();
                    if (clean.length != 6) return;
                    final n = int.tryParse(clean, radix: 16);
                    if (n == null) return;
                    _apply(HSVColor.fromColor(Color(0xFF000000 | n)));
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('A foto atualiza enquanto você arrasta.',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small editable number next to a slider: type a value and press Enter (or
/// click away) to apply it; it is clamped to the slider's range.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.enabled,
    required this.onSubmitted,
  });

  final double value;
  final double min;
  final double max;
  final String unit;
  final bool enabled;
  final ValueChanged<double> onSubmitted;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctl =
      TextEditingController(text: _fmt(widget.value));
  final FocusNode _focus = FocusNode();

  static String _fmt(double v) => v.round().toString();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // Follow the slider while the field isn't being edited.
    if (!_focus.hasFocus && _ctl.text != _fmt(widget.value)) {
      _ctl.text = _fmt(widget.value);
    }
  }

  void _commit() {
    final parsed = double.tryParse(_ctl.text.replaceAll(',', '.').trim());
    if (parsed == null) {
      _ctl.text = _fmt(widget.value);
      return;
    }
    final v = parsed.clamp(widget.min, widget.max).toDouble();
    _ctl.text = _fmt(v);
    if (v.round() != widget.value.round()) widget.onSubmitted(v);
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 70,
      height: 26,
      child: TextField(
        controller: _ctl,
        focusNode: _focus,
        enabled: widget.enabled,
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        keyboardType:
            const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          suffixText: widget.unit,
          suffixStyle: const TextStyle(fontSize: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// One settings block in the sidebar: numbered header + content + divider.
class _Section extends StatelessWidget {
  const _Section({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text('$number',
                        style: TextStyle(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(width: 22, height: 22, child: icon),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              child,
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
      ],
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
      size: const Size(22, 22),
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
    final stroke = (frameH * 0.09).clamp(1.5, 3.0);
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

/// Full-screen image viewer with pages. Each page is produced on demand by
/// [loader] (e.g. a high-res render) and cached. Zoom with the mouse wheel,
/// the +/- buttons or a pinch; the image is always kept inside the frame.
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
  static const double _maxScale = 8;
  late final PageController _controller;
  final TransformationController _zoom = TransformationController();
  final Map<int, Uint8List> _cache = {};
  final Set<int> _loading = {};
  final Map<int, double> _aspects = {}; // width / height per page
  final Set<int> _aspectLoading = {};
  Size? _viewerSize; // size of the image area on the current page
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    _controller = PageController(initialPage: widget.initialPage);
    _zoom.addListener(() => setState(() {}));
    _load(widget.initialPage);
    _load(widget.initialPage + 1);
  }

  @override
  void dispose() {
    _controller.dispose();
    _zoom.dispose();
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

  double get _scale => _zoom.value.getMaxScaleOnAxis();

  Future<void> _ensureAspect(int i, Uint8List bytes) async {
    if (_aspects.containsKey(i) || _aspectLoading.contains(i)) return;
    _aspectLoading.add(i);
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        final img = frame.image;
        final a = img.height == 0 ? 1.0 : img.width / img.height;
        img.dispose();
        if (mounted) setState(() => _aspects[i] = a);
      } finally {
        codec.dispose();
      }
    } catch (_) {
    } finally {
      _aspectLoading.remove(i);
    }
  }

  void _goTo(int i) {
    if (i < 0 || i >= widget.itemCount) return;
    _zoom.value = Matrix4.identity();
    _controller.jumpToPage(i); // no slide animation
  }

  /// Zooms to [target] around the viewport center and keeps the (viewport
  /// sized) child covering the frame, so it can never drift out of view.
  void _zoomTo(double target) {
    final size = _viewerSize ?? MediaQuery.of(context).size;
    final s = target.clamp(1.0, _maxScale);
    if (s <= 1.0) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final k = s / _scale;
    final c = Offset(size.width / 2, size.height / 2);
    final m = Matrix4.identity()
      ..translate(c.dx, c.dy)
      ..scale(k)
      ..translate(-c.dx, -c.dy);
    final next = m.multiplied(_zoom.value);
    final minTx = size.width - size.width * s;
    final minTy = size.height - size.height * s;
    final tx = next.storage[12].clamp(minTx, 0.0);
    final ty = next.storage[13].clamp(minTy, 0.0);
    next.setTranslationRaw(tx, ty, 0);
    _zoom.value = next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _goTo(_page - 1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _goTo(_page + 1),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.itemCount,
            physics: _scale > 1.01
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: (i) {
              _zoom.value = Matrix4.identity();
              setState(() => _page = i);
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
              final aspect = _aspects[i];
              if (aspect == null) _ensureAspect(i, bytes);
              final image = Image.memory(bytes,
                  fit: BoxFit.contain, gaplessPlayback: true);
              // The zoomable area is exactly the image: the black margins
              // around it ignore the wheel and the drag.
              return Center(
                child: aspect == null
                    ? image
                    : AspectRatio(
                        aspectRatio: aspect,
                        child: LayoutBuilder(
                          builder: (context, cons) {
                            if (i == _page) _viewerSize = cons.biggest;
                            return InteractiveViewer(
                              transformationController:
                                  i == _page ? _zoom : null,
                              minScale: 1,
                              maxScale: _maxScale,
                              trackpadScrollCausesScale: true,
                              child: image,
                            );
                          },
                        ),
                      ),
              );
            },
          ),
          // Double-click anywhere closes the viewer (buttons stay on top).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () => Navigator.of(context).pop(),
            ),
          ),
          // Top bar: counter + close.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  if (widget.itemCount > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6)),
                      child: Text('${_page + 1} / ${widget.itemCount}',
                          style: const TextStyle(color: Colors.white)),
                    ),
                  const Spacer(),
                  Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      iconSize: 28,
                      tooltip: 'Fechar (Esc)',
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Previous / next (also: drag with the mouse, ← → keys).
          if (widget.itemCount > 1) ...[
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 30,
                    tooltip: 'Anterior (←)',
                    icon: const Icon(Icons.chevron_left, color: Colors.white),
                    onPressed: _page > 0 ? () => _goTo(_page - 1) : null,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 30,
                    tooltip: 'Próxima (→)',
                    icon: const Icon(Icons.chevron_right, color: Colors.white),
                    onPressed: _page < widget.itemCount - 1
                        ? () => _goTo(_page + 1)
                        : null,
                  ),
                ),
              ),
            ),
          ],
          // Bottom: zoom controls.
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Menos zoom',
                        icon: const Icon(Icons.remove, color: Colors.white),
                        onPressed:
                            _scale > 1.01 ? () => _zoomTo(_scale / 1.5) : null,
                      ),
                      SizedBox(
                        width: 56,
                        child: Text('${(_scale * 100).round()}%',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white)),
                      ),
                      IconButton(
                        tooltip: 'Mais zoom',
                        icon: const Icon(Icons.add, color: Colors.white),
                        onPressed: _scale < _maxScale - 0.01
                            ? () => _zoomTo(_scale * 1.5)
                            : null,
                      ),
                      IconButton(
                        tooltip: 'Ajustar à tela',
                        icon: const Icon(Icons.fit_screen, color: Colors.white),
                        onPressed: _scale > 1.01 ? () => _zoomTo(1) : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }
}

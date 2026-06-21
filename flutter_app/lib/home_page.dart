import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gal/gal.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

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
  bool _centered = false; // false = left-to-right, true = centered rows

  // ---- Save state: incremental save into ONE album per project ----
  final Set<String> _savedPaths = {}; // photo paths already saved this project
  String? _currentAlbum; // album reused for the whole project
  _ProcessResult? _lastResult; // persistent result banner

  // Preview state.
  final Map<String, Uint8List> _photoCache = {};
  List<_Preview> _previews = [];
  int _previewToken = 0;
  Timer? _debounce;

  // Processing state.
  bool _processing = false;
  int _done = 0;
  int _total = 0;

  bool get _hasAnyLogo =>
      _bottomLogos.isNotEmpty || _topLeftLogos.isNotEmpty || _cornerLogo != null;

  /// Photos selected but not yet saved in this project.
  List<String> get _unsavedPaths =>
      _photoPaths.where((p) => !_savedPaths.contains(p)).toList();

  /// Controls (including the main-logo options) stay disabled until at least
  /// one photo is added, and lock again once the project has been saved (an
  /// album exists) — only adding more photos stays available after that.
  bool get _controlsEnabled =>
      !_processing && _currentAlbum == null && _photoPaths.isNotEmpty;
  bool get _canProcess =>
      !_processing && _hasAnyLogo && _unsavedPaths.isNotEmpty;
  bool get _allSaved =>
      _photoPaths.isNotEmpty && _hasAnyLogo && _unsavedPaths.isEmpty;

  @override
  void initState() {
    super.initState();
    _loadProject();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _textRecognizer.close();
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
    final phash = await compute(perceptualHash, bytes);
    final ocr = await _ocrLogo(path);
    if (!mounted) return;
    setState(() => _cornerLogo = LogoItem(_nextLogoId++, path,
        'asset:default_corner', bytes, phash, ocr.phones, ocr.texts));
  }

  // ---- Picking ----

  Future<void> _pickPhotos() async {
    // If a save is already running, confirm before queueing more photos.
    if (_processing) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Salvamento em andamento'),
          content: const Text(
              'O salvamento já está rodando. As fotos que você adicionar entram '
              'na fila e também serão salvas com as logos. Deseja adicionar mais?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Adicionar')),
          ],
        ),
      );
      if (ok != true) return;
    }
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

  // Max perceptual-hash (dHash) distance for two logos to count as "similar".
  // 0 = identical; higher = more tolerant (blocks more). 64 bits total.
  static const _kSimilarThreshold = 12;

  Future<void> _pickLogos(List<LogoItem> target) async {
    // Logos come from the photo gallery (same as the photos).
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    setState(() {
      _checkingLogos = true;
      _checkDone = 0;
      _checkTotal = picked.length;
    });
    // De-dup against logos already in the rows (and the main logo): by visual
    // SIMILARITY (perceptual hash), by file name, and by OCR'd phone/company
    // name. All heavy work runs off the main thread (compute / ML Kit), so the
    // UI stays responsive and shows "Verificando logo X de N".
    final existing = [
      ..._bottomLogos,
      ..._topLeftLogos,
      if (_cornerLogo != null) _cornerLogo!,
    ];
    final usedNames = existing.map((e) => _logoName(e.sourceKey)).toList();
    final usedPhashes = existing.map((e) => e.phash).toList();
    final usedPhones = existing.expand((e) => e.phones).toSet();
    final usedTexts = existing.expand((e) => e.texts).toSet();
    var skipped = 0;
    try {
      for (var i = 0; i < picked.length; i++) {
        setState(() => _checkDone = i + 1);
        await Future<void>.delayed(const Duration(milliseconds: 16)); // paint
        try {
          final x = picked[i];
          final bytes = await x.readAsBytes();
          final name = _logoName(x.name);
          // Decode/downscale/hash off the main thread, with a safety timeout so
          // a huge or odd image can never hang the whole flow.
          final analysis = await compute(analyzeLogo, bytes).timeout(
              const Duration(seconds: 20),
              onTimeout: () => LogoAnalysis(Uint8List(0), 0));
          final phash = analysis.phash;
          final path = await _copyBytesToApp(bytes, 'logos');
          // OCR the small flattened JPEG (fast); skip if it failed to produce.
          var phones = <String>{};
          var texts = <String>{};
          if (analysis.ocrJpeg.isNotEmpty) {
            final ocrPath = await _writeTemp(analysis.ocrJpeg);
            final ocr = await _ocrLogo(ocrPath);
            phones = ocr.phones;
            texts = ocr.texts;
            try {
              await File(ocrPath).delete();
            } catch (_) {}
          }
          final dupName =
              name.isNotEmpty && usedNames.any((u) => _namesRelated(u, name));
          final dupSimilar = phash != 0 &&
              usedPhashes
                  .any((p) => perceptualDistance(p, phash) <= _kSimilarThreshold);
          final dupPhone = phones.any(usedPhones.contains);
          final dupText = texts.any(usedTexts.contains);
          if (dupName || dupSimilar || dupPhone || dupText) {
            try {
              await File(path).delete();
            } catch (_) {}
            skipped++;
            continue;
          }
          target.add(
              LogoItem(_nextLogoId++, path, x.name, bytes, phash, phones, texts));
          usedNames.add(name);
          if (phash != 0) usedPhashes.add(phash);
          usedPhones.addAll(phones);
          usedTexts.addAll(texts);
        } catch (_) {
          // One bad logo shouldn't abort the rest.
        }
      }
    } finally {
      if (mounted) setState(() => _checkingLogos = false);
    }
    if (skipped > 0) {
      _snack('$skipped logo(s) ignorada(s): parecida(s), ou mesmo telefone/nome '
          'de uma já no projeto.');
    }
    _schedulePreview();
  }

  /// Writes [bytes] to a temporary file (for ML Kit OCR which needs a path).
  Future<String> _writeTemp(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final f = File(
        '${dir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}_${_fileSeq++}.jpg');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  /// OCRs a logo and extracts phone numbers and normalized text lines (e.g. the
  /// company name), used to block logos of the same business.
  Future<({Set<String> phones, Set<String> texts})> _ocrLogo(
      String path) async {
    final phones = <String>{};
    final texts = <String>{};
    try {
      final recognized = await _textRecognizer
          .processImage(InputImage.fromFilePath(path))
          .timeout(const Duration(seconds: 12));
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final raw = line.text;
          for (final m in RegExp(r'\d[\d\s().+\-]{6,}\d').allMatches(raw)) {
            final d = m.group(0)!.replaceAll(RegExp(r'\D'), '');
            if (d.length >= 8 && d.length <= 13) phones.add(d);
          }
          final norm = raw
              .toUpperCase()
              .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (norm.replaceAll(' ', '').length >= 6 &&
              RegExp(r'[A-Z]').hasMatch(norm)) {
            texts.add(norm);
          }
        }
      }
    } catch (_) {}
    return (phones: phones, texts: texts);
  }

  Future<void> _pickCornerLogo() async {
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _importing = true);
    final path = await _copyBytesToApp(bytes, 'logos');
    final phash = await compute(perceptualHash, bytes);
    final ocr = await _ocrLogo(path);
    setState(() {
      _cornerLogo = LogoItem(
          _nextLogoId++, path, x.name, bytes, phash, ocr.phones, ocr.texts);
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
    if (photos.isEmpty || !_hasAnyLogo) {
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
    // One render per photo (at a medium size) — used for BOTH the thumbnail and
    // the fullscreen viewer. Rendering is pure-Dart, so doing a single pass
    // (instead of a small + a 2560px pass) roughly halves the load time.
    final results = <_Preview>[];
    for (final path in photos) {
      final bytes = _photoCache[path] ??= await File(path).readAsBytes();
      if (token != _previewToken) return;
      final out = await compute(
          renderWatermark, _request(bytes, maxDim: 1280, quality: 88));
      if (token != _previewToken) return;
      final codec = await ui.instantiateImageCodec(out);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final aspect = image.height == 0 ? 1.0 : image.width / image.height;
      image.dispose();
      codec.dispose();
      if (token != _previewToken) return;
      results.add(_Preview(out, aspect));
      setState(() => _previews = List.of(results));
    }
    if (token == _previewToken && mounted) {
      setState(() => _renderingPreview = false);
    }
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
      png: png,
      maxDim: maxDim,
      quality: quality,
    );
  }

  // ---- Saving ----

  Future<void> _saveAll() async {
    if (_processing || !_hasAnyLogo) return;
    if (_unsavedPaths.isEmpty) return; // everything is already saved
    final granted = await Gal.requestAccess(toAlbum: true);
    if (!granted) {
      _snack('Permissão da galeria negada.');
      return;
    }
    // Keep the device awake so a long save isn't interrupted by auto-lock.
    await WakelockPlus.enable();
    // Reuse the project's album; create one (named by date/time) on first save.
    final album = _currentAlbum ?? _nextAlbum();
    setState(() {
      _processing = true;
      _currentAlbum = album;
      _lastResult = null;
      _done = 0;
      _total = _unsavedPaths.length;
    });

    // Process only photos not yet saved; photos ADDED mid-save are picked up too.
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
      if (next == null) break; // nothing left, including any added meanwhile
      processed.add(next);
      try {
        final bytes = _photoCache[next] ?? await File(next).readAsBytes();
        final out = await compute(renderWatermark, _request(bytes, png: true));
        final ts = DateTime.now().microsecondsSinceEpoch;
        await Gal.putImageBytes(out, album: album, name: 'watermarked_$ts.png');
        _savedPaths.add(next);
        saved++;
      } catch (_) {
        failed++;
      }
      setState(() {
        _done = processed.length;
        _total = processed.length + _unsavedPaths.length;
      });
    }

    await WakelockPlus.disable();
    await _addHistory(album, saved, failed);
    await _saveProject();
    if (!mounted) return;
    setState(() {
      _processing = false;
      _lastResult = _ProcessResult(saved: saved, failed: failed, album: album);
    });
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
            // Available once there are photos (or a saved project) to clear.
            onPressed: (_photoPaths.isNotEmpty || _savedPaths.isNotEmpty)
                ? _confirmNewProject
                : null,
            child: const Text('Novo projeto'),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Histórico',
            onPressed: _openHistory,
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
          if (_photoPaths.isNotEmpty && _hasAnyLogo) _previewBar(),
          Expanded(
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
                  hint: 'Encostadas, da esquerda para a direita, na base. '
                      'Tamanho e distância da esquerda valem para as de cima e de baixo.',
                  onAdd: () => _pickLogos(_bottomLogos),
                  sliders: [
                    _alignmentChooser(),
                    _slider('Tamanho (todas)', _logoSize, 5, 30,
                        (v) => setState(() => _logoSize = v)),
                    if (!_centered)
                      _slider('Distância da borda esquerda (todas)', _leftMargin,
                          0, 15, (v) => setState(() => _leftMargin = v)),
                    _slider('Opacidade (todas)', _logoOpacity, 0, 100,
                        (v) => setState(() => _logoOpacity = v)),
                    _slider('Distância da borda inferior', _bottomMargin, 0, 15,
                        (v) => setState(() => _bottomMargin = v)),
                  ],
                ),
                const SizedBox(height: 16),
                _logoCard(
                  number: 3,
                  title: _centered
                      ? 'Logos do topo'
                      : 'Logos do canto superior esquerdo',
                  placement: Placement.topLeft,
                  items: _topLeftLogos,
                  hint: 'Encostadas, da esquerda para a direita, no topo. '
                      'Tamanho e distância da esquerda valem para as de cima e de baixo.',
                  onAdd: () => _pickLogos(_topLeftLogos),
                  sliders: [
                    _alignmentChooser(),
                    _slider('Tamanho (todas)', _logoSize, 5, 30,
                        (v) => setState(() => _logoSize = v)),
                    if (!_centered)
                      _slider('Distância da borda esquerda (todas)', _leftMargin,
                          0, 15, (v) => setState(() => _leftMargin = v)),
                    _slider('Opacidade (todas)', _logoOpacity, 0, 100,
                        (v) => setState(() => _logoOpacity = v)),
                    _slider('Distância da borda superior', _topMargin, 0, 15,
                        (v) => setState(() => _topMargin = v)),
                  ],
                ),
                const SizedBox(height: 16),
                _cornerCard(),
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
        onTap: () => _openFullscreen(i),
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
    _openImagesFullscreen(_previews.map((e) => e.bytes).toList(), index);
  }

  /// Opens any list of image bytes (e.g. logos) in the zoomable fullscreen
  /// viewer, starting at [index].
  void _openImagesFullscreen(List<Uint8List> images, int index) {
    if (images.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenViewer(initialPage: index, images: images),
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
            onPressed: _pickPhotos,
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
                    onTap: () => _openImagesFullscreen(
                        items.map((e) => e.bytes).toList(), i),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 48,
                        height: 48,
                        color: Theme.of(context).colorScheme.surfaceVariant,
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
              onTap: () => _openImagesFullscreen([_cornerLogo!.bytes], 0),
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

  Widget _actionArea() {
    if (_processing) {
      final progress = _total == 0 ? 0.0 : _done / _total;
      return Column(
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text('Processando $_done de $_total…'),
          const SizedBox(height: 4),
          Text(
            'Você pode adicionar mais fotos — elas entram na fila. Mantenha o app aberto.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
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
            'Tudo salvo no álbum “$_currentAlbum”. Fotos novas vão para o mesmo '
            'álbum. Use “Novo projeto” para começar do zero.',
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
              ? 'As imagens são salvas num álbum nomeado pela data/hora.'
              : 'As novas fotos vão para o mesmo álbum “$_currentAlbum”.',
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
        subtitle: Text('Álbum “${r.album}”'),
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
                'Projeto já salvo no álbum “$_currentAlbum”. Ajustes e logos '
                'estão travados; fotos novas vão para o mesmo álbum com a mesma '
                'configuração. Para editar ou usar outras fotos, comece um novo '
                'projeto.',
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
            'Isso limpa as fotos e logos atuais. As imagens já salvas na '
            'galeria são mantidas.'),
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
      _photoCache.clear();
      _logoSize = 22;
      _leftMargin = 1;
      _logoOpacity = 90;
      _bottomMargin = 2;
      _topMargin = 2;
      _cornerHeight = 22;
      _cornerMargin = 2;
      _centered = false;
    });
    await _installDefaultCorner();
    await _saveProject();
  }

  Widget _alignmentChooser() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Alinhamento das logos:',
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
                color: Theme.of(context).colorScheme.surfaceVariant,
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

/// Full-screen, swipeable image viewer over the (pre-rendered) images. No
/// spinner — the images are already prepared. InteractiveViewer keeps panning
/// within the image bounds.
class _FullscreenViewer extends StatefulWidget {
  const _FullscreenViewer({required this.initialPage, required this.images});

  final int initialPage;
  final List<Uint8List> images;

  @override
  State<_FullscreenViewer> createState() => _FullscreenViewerState();
}

class _FullscreenViewerState extends State<_FullscreenViewer> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialPage);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.images.length,
            itemBuilder: (c, i) => InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.memory(widget.images[i], fit: BoxFit.contain),
              ),
            ),
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

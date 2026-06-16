import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();

  final List<XFile> _photos = [];
  final List<LogoItem> _bottomLogos = [];
  final List<LogoItem> _topLeftLogos = [];
  LogoItem? _cornerLogo;

  int _nextLogoId = 0;

  // Adjustments (percent of the photo's shortest side).
  // Size and left margin are SHARED by the bottom and top rows.
  double _logoSize = 22;
  double _leftMargin = 1;
  double _logoOpacity = 90; // shared by both rows (not the main logo)
  double _bottomMargin = 2; // distance from the bottom edge
  double _topMargin = 2; // distance from the top edge
  double _cornerHeight = 22, _cornerMargin = 2;
  bool _centered = false; // false = left-to-right, true = centered rows

  // Preview state.
  final Map<String, Uint8List> _photoCache = {};
  List<_Preview> _previews = [];
  List<Uint8List> _hiResPreviews = [];
  int _previewToken = 0;
  Timer? _debounce;

  // Processing state.
  bool _processing = false;
  int _done = 0;
  int _total = 0;

  bool get _hasAnyLogo =>
      _bottomLogos.isNotEmpty || _topLeftLogos.isNotEmpty || _cornerLogo != null;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
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
    final existing = _photos.map((p) => p.path).toSet();
    setState(() {
      _photos.addAll(picked.where((p) => !existing.contains(p.path)));
    });
    _schedulePreview();
  }

  Future<void> _pickLogos(List<LogoItem> target) async {
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    // The same logo can't be in both rows.
    final other = identical(target, _bottomLogos) ? _topLeftLogos : _bottomLogos;
    final blocked = other.map((e) => e.path).toSet();
    var skipped = 0;
    for (final x in picked) {
      if (blocked.contains(x.path)) {
        skipped++;
        continue;
      }
      final bytes = await x.readAsBytes();
      target.add(LogoItem(_nextLogoId++, x.path, bytes));
    }
    setState(() {});
    if (skipped > 0) {
      _snack(identical(target, _bottomLogos)
          ? 'Logo(s) já usada(s) no topo — ignorada(s).'
          : 'Logo(s) já usada(s) na base — ignorada(s).');
    }
    _schedulePreview();
  }

  Future<void> _pickCornerLogo() async {
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _cornerLogo = LogoItem(_nextLogoId++, x.path, bytes));
    _schedulePreview();
  }

  // ---- Preview ----

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _recomputePreviews);
  }

  Future<void> _recomputePreviews() async {
    final token = ++_previewToken;
    final photos = _photos.take(kMaxPreview).toList();
    if (photos.isEmpty || !_hasAnyLogo) {
      setState(() {
        _previews = [];
        _hiResPreviews = [];
      });
      return;
    }
    final results = <_Preview>[];
    for (final p in photos) {
      final bytes = _photoCache[p.path] ??= await p.readAsBytes();
      if (token != _previewToken) return;
      final out =
          await compute(renderWatermark, _request(bytes, maxDim: 900, quality: 85));
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

    // Pre-render high-resolution versions (compressed bytes are cheap to hold),
    // so the full-screen viewer is already crisp without a spinner.
    final hi = <Uint8List>[];
    for (final p in photos) {
      final bytes = _photoCache[p.path]!;
      if (token != _previewToken) return;
      final out =
          await compute(renderWatermark, _request(bytes, maxDim: 2560, quality: 92));
      if (token != _previewToken) return;
      hi.add(out);
      setState(() => _hiResPreviews = List.of(hi));
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
    if (_processing || _photos.isEmpty || !_hasAnyLogo) return;
    final granted = await Gal.requestAccess(toAlbum: true);
    if (!granted) {
      _snack('Permissão da galeria negada.');
      return;
    }
    // Keep the device awake so a long save isn't interrupted by auto-lock.
    await WakelockPlus.enable();
    final album = _nextAlbum();
    setState(() {
      _processing = true;
      _done = 0;
      _total = _photos.length;
    });

    // Process by path so photos ADDED during the save are still picked up; each
    // photo is processed exactly once.
    final processed = <String>{};
    var saved = 0, failed = 0;
    while (mounted) {
      XFile? next;
      for (final p in _photos) {
        if (!processed.contains(p.path)) {
          next = p;
          break;
        }
      }
      if (next == null) break; // nothing left, including any added meanwhile
      processed.add(next.path);
      try {
        final bytes = await next.readAsBytes();
        final out = await compute(renderWatermark, _request(bytes, png: true));
        final ts = DateTime.now().microsecondsSinceEpoch;
        await Gal.putImageBytes(out, album: album, name: 'watermarked_$ts.png');
        saved++;
      } catch (_) {
        failed++;
      }
      setState(() {
        _done = processed.length;
        _total = _photos.length;
      });
    }

    await WakelockPlus.disable();
    await _addHistory(album, saved, failed);
    setState(() => _processing = false);
    _snack(failed == 0
        ? 'Pronto! $saved foto(s) salva(s) no álbum "$album".'
        : '$saved salva(s), $failed falharam.');
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
        title: const Text('Photo Watermark'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Histórico',
            onPressed: _openHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_photos.isNotEmpty && _hasAnyLogo) _previewBar(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
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
              _photos.length <= 1
                  ? 'Pré-visualização (1ª foto)'
                  : 'Pré-visualização (primeiras ${_photos.length.clamp(0, kMaxPreview)} fotos) — arraste para o lado',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 208,
              child: _previews.isEmpty
                  ? const Center(child: CircularProgressIndicator())
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
    final lowRes = _previews.map((e) => e.bytes).toList();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenViewer(
          initialPage: index,
          // Use the pre-rendered high-res when available, else the low-res.
          images: [
            for (var i = 0; i < lowRes.length; i++)
              i < _hiResPreviews.length ? _hiResPreviews[i] : lowRes[i]
          ],
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
            onPressed: _pickPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Adicionar fotos'),
          ),
          if (_photos.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${_photos.length} foto(s)',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            SizedBox(
              height: 76,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _thumb(
                  enabled: !_processing,
                  child: Image.file(File(_photos[i].path), fit: BoxFit.cover),
                  onRemove: () {
                    setState(() => _photos.removeAt(i));
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
            onPressed: (_photos.isEmpty || _processing) ? null : onAdd,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Adicionar logos'),
          ),
          const SizedBox(height: 8),
          Text(
            _photos.isEmpty
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
              buildDefaultDragHandles: !_processing,
              itemCount: items.length,
              onReorder: (oldIndex, newIndex) {
                if (_processing) return;
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
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 48,
                      height: 48,
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      child: Image.memory(item.bytes, fit: BoxFit.contain),
                    ),
                  ),
                  title: Text('Logo ${i + 1}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _processing
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
            onPressed:
                (_photos.isEmpty || _processing) ? null : _pickCornerLogo,
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
              enabled: !_processing,
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
    final canProcess = _photos.isNotEmpty && _hasAnyLogo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: canProcess ? _saveAll : null,
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Aplicar e salvar tudo'),
        ),
        const SizedBox(height: 6),
        Text('As imagens são salvas no álbum “Watermarked”.',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
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
              onSelected: _processing
                  ? null
                  : (s) {
                      setState(() => _centered = false);
                      _schedulePreview();
                    },
            ),
            ChoiceChip(
              label: const Text('Centralizado'),
              selected: _centered,
              onSelected: _processing
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
          onChanged: _processing
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
    bool enabled = true,
  }) {
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 76,
              height: 76,
              color: Theme.of(context).colorScheme.surfaceVariant,
              child: child,
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
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

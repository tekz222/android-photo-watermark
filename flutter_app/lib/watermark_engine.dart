import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A pre-rasterized text overlay (transparent PNG drawn by the UI with the
/// system's fonts). Always centered horizontally; [top] places its vertical
/// center as a fraction of the photo height, [height] scales it as a fraction
/// of the photo's shortest side.
class TextOverlay {
  TextOverlay({
    required this.png,
    required this.height,
    required this.top,
    this.contentRatio = 1.0,
  });
  final Uint8List png;
  final double height;
  final double top;

  /// Fraction of the PNG height taken by the text's own line box (the rest is
  /// padding for the outline), so [height] refers to the glyphs, not the pad.
  final double contentRatio;
}

/// All inputs needed to render one watermarked photo. This object is passed
/// across an isolate via [compute], so every field is a plain, copyable value.
class WatermarkRequest {
  WatermarkRequest({
    required this.photoBytes,
    required this.bottomLogos,
    required this.topLeftLogos,
    required this.cornerLogo,
    required this.bottomHeight,
    required this.bottomMargin,
    required this.bottomLeft,
    required this.topLeftHeight,
    required this.topLeftTop,
    required this.topLeftLeft,
    required this.cornerHeight,
    required this.cornerMargin,
    this.rowOpacity = 1.0,
    this.centered = false,
    this.spacing = 0.0,
    this.textOverlays = const [],
    this.png = false,
    this.maxDim,
    this.quality = 95,
  });

  final Uint8List photoBytes;

  /// Ordered logo bytes (duplicates allowed) for each placement.
  final List<Uint8List> bottomLogos;
  final List<Uint8List> topLeftLogos;
  final Uint8List? cornerLogo;

  // Fractions of the photo's shortest side.
  final double bottomHeight;
  final double bottomMargin;
  final double bottomLeft;
  final double topLeftHeight;
  final double topLeftTop;
  final double topLeftLeft;
  final double cornerHeight;
  final double cornerMargin;

  /// Opacity (0..1) applied to the bottom and top rows (not the corner logo).
  final double rowOpacity;

  /// false = bottom row anchored left; true = bottom row centered.
  /// The top row is ALWAYS anchored left.
  final bool centered;

  /// Horizontal gap between logos in a row, as a fraction of the shortest side.
  final double spacing;

  /// Text overlays drawn on top of everything.
  final List<TextOverlay> textOverlays;

  /// Encode the result as lossless PNG instead of JPEG.
  final bool png;

  /// Optional longest-edge cap (used to keep the live preview fast). When null
  /// the photo is processed at full resolution.
  final int? maxDim;
  final int quality;
}

/// Composites the logos onto the photo and returns encoded JPEG bytes.
///
/// Drawing order (bottom layer first): top-left row, bottom row, then the
/// top-right main logo on top. Rows run left-to-right with logos touching.
///
/// Top-level so it can run inside [compute] off the UI thread.
Uint8List renderWatermark(WatermarkRequest r) {
  var photo = img.decodeImage(r.photoBytes);
  if (photo == null) return r.photoBytes;
  photo = img.bakeOrientation(photo);

  final maxDim = r.maxDim;
  if (maxDim != null && (photo.width > maxDim || photo.height > maxDim)) {
    photo = photo.width >= photo.height
        ? img.copyResize(photo, width: maxDim)
        : img.copyResize(photo, height: maxDim);
  }

  final shortest =
      (photo.width < photo.height ? photo.width : photo.height).toDouble();

  // Decode each distinct logo only once (duplicates share the same bytes ref).
  final cache = <Uint8List, img.Image?>{};
  img.Image? decode(Uint8List bytes) => cache.putIfAbsent(bytes, () {
        final d = img.decodeImage(bytes);
        return d == null ? null : img.bakeOrientation(d);
      });

  final gap = shortest * r.spacing;

  // Top-left / top row (lowest layer). Always anchored to the left; only the
  // bottom row honors the "centered" option.
  final topH = shortest * r.topLeftHeight;
  _drawRow(
    photo,
    r.topLeftLogos,
    decode,
    height: topH,
    startX: shortest * r.topLeftLeft,
    top: shortest * r.topLeftTop,
    opacity: r.rowOpacity,
    gap: gap,
  );

  // Bottom row.
  final bottomH = shortest * r.bottomHeight;
  final bottomStartX = r.centered
      ? (photo.width - _rowWidth(r.bottomLogos, decode, bottomH, gap)) / 2
      : shortest * r.bottomLeft;
  _drawRow(
    photo,
    r.bottomLogos,
    decode,
    height: bottomH,
    startX: bottomStartX,
    top: photo.height - shortest * r.bottomMargin - bottomH,
    opacity: r.rowOpacity,
    gap: gap,
  );

  // Top-right main logo (top layer).
  final cornerBytes = r.cornerLogo;
  if (cornerBytes != null) {
    final logo = decode(cornerBytes);
    if (logo != null) {
      final h = (shortest * r.cornerHeight).round().clamp(1, photo.height);
      final resized = _resize(logo, height: h);
      final margin = shortest * r.cornerMargin;
      final x = (photo.width - margin - resized.width).round();
      final y = margin.round();
      img.compositeImage(photo, resized, dstX: x, dstY: y);
    }
  }

  // Text overlays (top-most layer): centered horizontally, vertical center at
  // [TextOverlay.top]. Shrunk to the photo width if a text is too wide.
  for (final t in r.textOverlays) {
    final text = decode(t.png);
    if (text == null) continue;
    final ratio = t.contentRatio > 0 ? t.contentRatio : 1.0;
    final h = (shortest * t.height / ratio).round().clamp(1, photo.height);
    var resized = _resize(text, height: h);
    if (resized.width > photo.width) {
      resized = _resize(text, width: photo.width);
    }
    final x = ((photo.width - resized.width) / 2).round();
    final maxY = photo.height - resized.height;
    var y = (t.top * photo.height - resized.height / 2).round();
    y = maxY <= 0 ? 0 : y.clamp(0, maxY);
    img.compositeImage(photo, resized, dstX: x, dstY: y);
  }

  return r.png ? img.encodePng(photo) : img.encodeJpg(photo, quality: r.quality);
}

void _drawRow(
  img.Image dst,
  List<Uint8List> logos,
  img.Image? Function(Uint8List) decode, {
  required double height,
  required double startX,
  required double top,
  double opacity = 1.0,
  double gap = 0.0,
}) {
  if (logos.isEmpty) return;
  final h = height.round().clamp(1, dst.height);
  final y = top.round();
  var x = startX;
  for (final bytes in logos) {
    final logo = decode(bytes);
    if (logo == null) continue;
    final resized = _withOpacity(_resize(logo, height: h), opacity);
    img.compositeImage(dst, resized, dstX: x.round(), dstY: y);
    x += resized.width + gap;
    if (x > dst.width) break; // Stop once the row has left the frame.
  }
}

/// Total width of [logos] laid out at the given [height] with [gap] pixels
/// between neighbours.
double _rowWidth(
  List<Uint8List> logos,
  img.Image? Function(Uint8List) decode,
  double height,
  double gap,
) {
  double w = 0;
  var n = 0;
  for (final bytes in logos) {
    final logo = decode(bytes);
    if (logo == null) continue;
    w += height * (logo.width / logo.height);
    n++;
  }
  if (n > 1) w += gap * (n - 1);
  return w;
}

/// Resizes with a filter that suits the direction: box-average when shrinking
/// (no jagged edges on logos and text), linear when enlarging. Palette images
/// are expanded to RGBA first, since the filters work on real pixel values.
img.Image _resize(img.Image src, {int? width, int? height}) {
  final s = src.hasPalette ? src.convert(numChannels: 4) : src;
  final targetH = height ?? (width! * s.height / s.width);
  final shrinking = targetH < s.height;
  return img.copyResize(
    s,
    width: width,
    height: height,
    interpolation:
        shrinking ? img.Interpolation.average : img.Interpolation.linear,
  );
}

/// Returns a copy of [src] with its alpha scaled by [opacity] (0..1).
img.Image _withOpacity(img.Image src, double opacity) {
  if (opacity >= 1.0) return src;
  final out = src.convert(numChannels: 4);
  for (final p in out) {
    p.a = p.a * opacity;
  }
  return out;
}

/// Perceptual difference-hash (dHash) of an image, for visual-similarity checks.
/// Returns a 64-bit fingerprint; two images are "similar" when the Hamming
/// distance between their hashes is small. Top-level so it can run in an isolate
/// via [compute].
int perceptualHash(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return 0;
  // Flatten transparency onto white so logos (transparent PNGs) compare on
  // their visible shape, then reduce to a 9x8 grayscale and build the dHash.
  final flat = img.Image(width: decoded.width, height: decoded.height);
  img.fill(flat, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, decoded);
  final small = img.copyResize(img.grayscale(flat), width: 9, height: 8);
  var hash = 0;
  var bit = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final left = small.getPixel(x, y).r;
      final right = small.getPixel(x + 1, y).r;
      if (left > right) hash |= (1 << bit);
      bit++;
    }
  }
  return hash;
}

/// Number of differing bits between two perceptual hashes (0 = identical).
int perceptualDistance(int a, int b) {
  var x = a ^ b;
  var count = 0;
  while (x != 0) {
    count += x & 1;
    x >>= 1;
  }
  return count;
}

/// Result of analyzing a logo off the main thread: a downscaled JPEG (flattened
/// on white) suitable for fast OCR, plus the perceptual hash.
class LogoAnalysis {
  LogoAnalysis(this.ocrJpeg, this.phash);
  final Uint8List ocrJpeg;
  final int phash;
}

/// Decodes [bytes] once, downscales (cap longest side at 1024) and flattens
/// transparency onto white, then returns a small JPEG for OCR plus the dHash.
/// Top-level so it can run in an isolate via [compute] (keeps the UI smooth).
LogoAnalysis analyzeLogo(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return LogoAnalysis(Uint8List(0), 0);
  var work = decoded;
  final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longest > 1024) {
    work = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: 1024)
        : img.copyResize(decoded, height: 1024);
  }
  final flat = img.Image(width: work.width, height: work.height);
  img.fill(flat, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, work);

  final gray = img.copyResize(img.grayscale(flat), width: 9, height: 8);
  var hash = 0;
  var bit = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      if (gray.getPixel(x, y).r > gray.getPixel(x + 1, y).r) hash |= (1 << bit);
      bit++;
    }
  }
  final jpeg = Uint8List.fromList(img.encodeJpg(flat, quality: 85));
  return LogoAnalysis(jpeg, hash);
}

/// Downscales an image for the live preview so re-rendering on every slider
/// change is fast. [keepAlpha] true -> PNG (logos, preserves transparency);
/// false -> JPEG (photos). Bakes EXIF orientation so the small copy is upright.
/// Top-level so it runs in an isolate via [compute]. Args: (bytes, maxSide, keepAlpha).
Uint8List downscaleImage((Uint8List, int, bool) args) {
  final (bytes, maxSide, keepAlpha) = args;
  var decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  decoded = img.bakeOrientation(decoded);
  final longest =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  final out = longest <= maxSide
      ? decoded
      : (decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxSide)
          : img.copyResize(decoded, height: maxSide));
  return Uint8List.fromList(
      keepAlpha ? img.encodePng(out) : img.encodeJpg(out, quality: 85));
}

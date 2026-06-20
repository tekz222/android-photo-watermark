import 'dart:typed_data';

import 'package:image/image.dart' as img;

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

  /// false = rows anchored left (left-to-right); true = rows centered.
  final bool centered;

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

  // Top-left / top row (lowest layer).
  final topH = shortest * r.topLeftHeight;
  final topStartX = r.centered
      ? (photo.width - _rowWidth(r.topLeftLogos, decode, topH)) / 2
      : shortest * r.topLeftLeft;
  _drawRow(
    photo,
    r.topLeftLogos,
    decode,
    height: topH,
    startX: topStartX,
    top: shortest * r.topLeftTop,
    opacity: r.rowOpacity,
  );

  // Bottom row.
  final bottomH = shortest * r.bottomHeight;
  final bottomStartX = r.centered
      ? (photo.width - _rowWidth(r.bottomLogos, decode, bottomH)) / 2
      : shortest * r.bottomLeft;
  _drawRow(
    photo,
    r.bottomLogos,
    decode,
    height: bottomH,
    startX: bottomStartX,
    top: photo.height - shortest * r.bottomMargin - bottomH,
    opacity: r.rowOpacity,
  );

  // Top-right main logo (top layer).
  final cornerBytes = r.cornerLogo;
  if (cornerBytes != null) {
    final logo = decode(cornerBytes);
    if (logo != null) {
      final h = (shortest * r.cornerHeight).round().clamp(1, photo.height);
      final resized = img.copyResize(logo, height: h);
      final margin = shortest * r.cornerMargin;
      final x = (photo.width - margin - resized.width).round();
      final y = margin.round();
      img.compositeImage(photo, resized, dstX: x, dstY: y);
    }
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
}) {
  if (logos.isEmpty) return;
  final h = height.round().clamp(1, dst.height);
  final y = top.round();
  var x = startX;
  for (final bytes in logos) {
    final logo = decode(bytes);
    if (logo == null) continue;
    final resized = _withOpacity(img.copyResize(logo, height: h), opacity);
    img.compositeImage(dst, resized, dstX: x.round(), dstY: y);
    x += resized.width;
    if (x > dst.width) break; // Stop once the row has left the frame.
  }
}

/// Total width of [logos] laid out touching at the given [height].
double _rowWidth(
  List<Uint8List> logos,
  img.Image? Function(Uint8List) decode,
  double height,
) {
  double w = 0;
  for (final bytes in logos) {
    final logo = decode(bytes);
    if (logo == null) continue;
    w += height * (logo.width / logo.height);
  }
  return w;
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

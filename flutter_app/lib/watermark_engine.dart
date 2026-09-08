import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Image bytes plus a stable key, so a long-lived renderer can keep the decoded
/// image and skip decoding the next time the same source is used.
class ImageSrc {
  const ImageSrc(this.key, this.bytes);
  final String key;
  final Uint8List bytes;
}

/// Small LRU cache of decoded images (used by the preview worker isolate).
class DecodedCache {
  DecodedCache({this.capacity = 24});
  final int capacity;
  final Map<String, img.Image> _m = {}; // insertion-ordered: first = oldest

  img.Image? get(String key) {
    final v = _m.remove(key);
    if (v != null) _m[key] = v; // move to most-recent
    return v;
  }

  void put(String key, img.Image v) {
    _m.remove(key);
    _m[key] = v;
    while (_m.length > capacity) {
      _m.remove(_m.keys.first);
    }
  }

  void clear() => _m.clear();
}

/// A pre-rasterized text overlay (transparent PNG drawn by the UI with the
/// system's fonts). Always centered horizontally; [top] places its vertical
/// center as a fraction of the photo height, [height] scales it as a fraction
/// of the photo's shortest side.
class TextOverlay {
  TextOverlay({
    required this.src,
    required this.height,
    required this.top,
    this.contentRatio = 1.0,
  });
  final ImageSrc src;
  final double height;
  final double top;

  /// Fraction of the PNG height taken by the text's own line box (the rest is
  /// padding for the outline), so [height] refers to the glyphs, not the pad.
  final double contentRatio;
}

/// All inputs needed to render one watermarked photo. This object is passed
/// across an isolate, so every field is a plain, copyable value.
class WatermarkRequest {
  WatermarkRequest({
    required this.photo,
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

  final ImageSrc photo;

  /// Ordered logos (duplicates allowed) for each placement.
  final List<ImageSrc> bottomLogos;
  final List<ImageSrc> topLeftLogos;
  final ImageSrc? cornerLogo;

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

  /// Optional longest-edge cap. When null the photo is processed at full
  /// resolution.
  final int? maxDim;
  final int quality;
}

/// Composites the logos and texts onto the photo and returns encoded bytes.
///
/// Drawing order (bottom layer first): top-left row, bottom row, the top-right
/// main logo, then the texts.
///
/// Top-level so it can run inside `compute` (no [cache]) or in the preview
/// worker isolate, where [cache] keeps decoded sources between renders.
Uint8List renderWatermark(WatermarkRequest r, {DecodedCache? cache}) {
  img.Image? load(ImageSrc s) {
    final hit = cache?.get(s.key);
    if (hit != null) return hit;
    final d = img.decodeImage(s.bytes);
    if (d == null) return null;
    final o = img.bakeOrientation(d);
    cache?.put(s.key, o);
    return o;
  }

  var photo = load(r.photo);
  if (photo == null) return r.photo.bytes;

  final maxDim = r.maxDim;
  if (maxDim != null && (photo.width > maxDim || photo.height > maxDim)) {
    photo = photo.width >= photo.height
        ? img.copyResize(photo, width: maxDim)
        : img.copyResize(photo, height: maxDim);
  } else if (cache != null) {
    photo = photo.clone(); // never draw onto the cached original
  }

  final shortest =
      (photo.width < photo.height ? photo.width : photo.height).toDouble();

  // Decode each distinct source only once per render.
  final local = <String, img.Image?>{};
  img.Image? decode(ImageSrc s) => local.putIfAbsent(s.key, () => load(s));

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

  // Top-right main logo.
  final corner = r.cornerLogo;
  if (corner != null) {
    final logo = decode(corner);
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
    final text = decode(t.src);
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
  List<ImageSrc> logos,
  img.Image? Function(ImageSrc) decode, {
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
  for (final src in logos) {
    final logo = decode(src);
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
  List<ImageSrc> logos,
  img.Image? Function(ImageSrc) decode,
  double height,
  double gap,
) {
  double w = 0;
  var n = 0;
  for (final src in logos) {
    final logo = decode(src);
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

/// Downscales an image for the live preview so re-rendering on every change
/// is fast. [keepAlpha] true -> PNG (logos, preserves transparency);
/// false -> JPEG (photos). Bakes EXIF orientation so the small copy is upright.
/// Top-level so it runs in an isolate via `compute`. Args: (bytes, maxSide, keepAlpha).
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

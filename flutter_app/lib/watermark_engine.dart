import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'models.dart';

/// Image bytes plus a stable key, so a long-lived renderer can keep the decoded
/// image and skip decoding the next time the same source is used.
class ImageSrc {
  const ImageSrc(this.key, this.bytes, {this.rawWidth, this.rawHeight});
  final String key;

  /// Encoded image (JPEG/PNG), or raw straight-alpha RGBA pixels when
  /// [rawWidth]/[rawHeight] are set (no decoding needed).
  final Uint8List bytes;
  final int? rawWidth;
  final int? rawHeight;
}

/// Small LRU cache of decoded images (used by the preview worker isolate).
class DecodedCache {
  DecodedCache({this.capacity = 24});
  final int capacity;
  final Map<String, img.Image> _m = {}; // insertion-ordered: first = oldest
  final Map<String, img.Image> _pinned = {}; // never evicted (text rasters)

  img.Image? get(String key) {
    final p = _pinned[key];
    if (p != null) return p;
    final v = _m.remove(key);
    if (v != null) _m[key] = v; // move to most-recent
    return v;
  }

  /// Keeps [v] under [key] until [clear] or until another image is pinned
  /// with the same [group] prefix (e.g. a text that was re-rasterized).
  void pin(String key, img.Image v, {String? group}) {
    if (group != null) {
      _pinned.removeWhere((k, _) => k.startsWith(group));
    }
    _pinned[key] = v;
  }

  void put(String key, img.Image v) {
    _m.remove(key);
    _m[key] = v;
    while (_m.length > capacity) {
      _m.remove(_m.keys.first);
    }
  }

  void clear() {
    _m.clear();
    _pinned.clear();
  }
}

/// Builds an image from raw straight-alpha RGBA pixels.
img.Image imageFromRaw(int w, int h, Uint8List bytes) => img.Image.fromBytes(
      width: w,
      height: h,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

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
    required this.cornerMarginTop,
    required this.cornerMarginRight,
    this.rowOpacity = 1.0,
    this.centered = false,
    this.spacing = 0.0,
    this.textOverlays = const [],
    this.png = false,
    this.maxDim,
    this.quality = 95,
    this.topGradient = false,
    this.bottomGradient = false,
    this.topGradientHeight,
    this.bottomGradientHeight,
    this.gradientColor = 0xFF000000,
    this.gradientOpacity = 1.0,
    this.imageSettings,
    // Extra logos for bottom row (above leftmost/rightmost)
    this.bottomLeftTopLogo,
    this.bottomRightTopLogo,
    this.bottomLeftTopMargin = 2.0,
    this.bottomRightTopMargin = 2.0,
    // Extra logo for top-left row (below leftmost)
    this.topLeftBottomLogo,
    this.topLeftBottomMargin = 2.0,
    // Optional reference shortest side for consistent logo sizing across photos.
    // When provided, logos are sized relative to this value instead of each
    // photo's actual shortest side. Used in auto mode to ensure logos that fit
    // on the smallest photo also fit on larger photos without clipping.
    this.referenceShortestSide,
  });

  final ImageSrc photo;

  /// Ordered logos (duplicates allowed) for each placement.
  final List<ImageSrc> bottomLogos;
  final List<ImageSrc> topLeftLogos;
  final ImageSrc? cornerLogo;

  // Extra logos for bottom row (placed above the main row)
  final ImageSrc? bottomLeftTopLogo;   // Above leftmost bottom logo
  final ImageSrc? bottomRightTopLogo;  // Above rightmost bottom logo
  final double bottomLeftTopMargin;
  final double bottomRightTopMargin;

  // Extra logo for top-left row (placed below the main row)
  final ImageSrc? topLeftBottomLogo;   // Below leftmost top-left logo
  final double topLeftBottomMargin;

  // Fractions of the photo's shortest side.
  final double bottomHeight;
  final double bottomMargin;
  final double bottomLeft;
  final double topLeftHeight;
  final double topLeftTop;
  final double topLeftLeft;
  final double cornerHeight;
  final double cornerMarginTop;
  final double cornerMarginRight;

  /// Opacity (0..1) applied to the bottom and top rows (not the corner logo).
  final double rowOpacity;

  /// false = bottom row anchored left; true = bottom row centered.
  /// The top row is ALWAYS anchored left.
  final bool centered;

  /// Optional reference shortest side for consistent logo sizing.
  /// If null, each photo's own shortest side is used.
  final double? referenceShortestSide;

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

  /// If true, draw a gradient from the top edge.
  final bool topGradient;

  /// If true, draw a gradient from the bottom edge.
  final bool bottomGradient;

  /// Height of the top gradient as a fraction of the shortest side.
  /// Defaults to [topLeftHeight] if not specified.
  final double? topGradientHeight;

  /// Height of the bottom gradient as a fraction of the shortest side.
  /// Defaults to [bottomHeight] if not specified.
  final double? bottomGradientHeight;

  /// Color of the gradient (ARGB). Default is black. Used for both top and bottom.
  final int gradientColor;

  /// Opacity of the gradient (0.0 to 1.0). Default is 1.0. Used for both top and bottom.
  final double gradientOpacity;

  /// Per-image custom settings that override global logo size/margin for this image.
  final ImageSettings? imageSettings;

  /// Returns the effective bottom logo size for this image (custom or global).
  double effectiveBottomHeight() => imageSettings?.enabled == true && imageSettings?.bottomLogoSize != null
      ? imageSettings!.bottomLogoSize!
      : bottomHeight;

  /// Returns the effective bottom logo margin for this image (custom or global).
  double effectiveBottomMargin() => imageSettings?.enabled == true && imageSettings?.bottomLogoMargin != null
      ? imageSettings!.bottomLogoMargin!
      : bottomMargin;

  /// Returns the effective top-left logo size for this image (custom or global).
  double effectiveTopLeftHeight() => imageSettings?.enabled == true && imageSettings?.topLeftLogoSize != null
      ? imageSettings!.topLeftLogoSize!
      : topLeftHeight;

  /// Returns the effective top-left logo top margin for this image (custom or global).
  double effectiveTopLeftTop() => imageSettings?.enabled == true && imageSettings?.topLeftLogoMarginTop != null
      ? imageSettings!.topLeftLogoMarginTop!
      : topLeftTop;

  /// Returns the effective top-left logo left margin for this image (custom or global).
  double effectiveTopLeftLeft() => imageSettings?.enabled == true && imageSettings?.topLeftLogoMarginLeft != null
      ? imageSettings!.topLeftLogoMarginLeft!
      : topLeftLeft;

  /// Returns the effective corner logo size for this image (custom or global).
  double effectiveCornerHeight() => imageSettings?.enabled == true && imageSettings?.cornerLogoSize != null
      ? imageSettings!.cornerLogoSize!
      : cornerHeight;

  /// Returns the effective corner logo top margin for this image (custom or global).
  double effectiveCornerMarginTop() => imageSettings?.enabled == true && imageSettings?.cornerLogoMarginTop != null
      ? imageSettings!.cornerLogoMarginTop!
      : cornerMarginTop;

  /// Returns the effective corner logo right margin for this image (custom or global).
  double effectiveCornerMarginRight() => imageSettings?.enabled == true && imageSettings?.cornerLogoMarginRight != null
      ? imageSettings!.cornerLogoMarginRight!
      : cornerMarginRight;

  /// Returns the effective spacing for this image (custom or global).
  double effectiveSpacing() => imageSettings?.enabled == true && imageSettings?.logoSpacing != null
      ? imageSettings!.logoSpacing!
      : spacing;

  /// Returns the effective bottom row spacing for this image (custom or global).
  double effectiveBottomSpacing() {
    final s = imageSettings;
    if (s?.enabled == true) {
      if (s!.useGlobalSpacing && s.logoSpacing != null) return s.logoSpacing!;
      if (s.useBottomSpacing && s.logoSpacing != null) return s.logoSpacing!;
    }
    return spacing;
  }

  /// Returns the effective top-left row spacing for this image (custom or global).
  double effectiveTopLeftSpacing() {
    final s = imageSettings;
    if (s?.enabled == true) {
      if (s!.useGlobalSpacing && s.logoSpacing != null) return s.logoSpacing!;
      if (s.useTopLeftSpacing && s.logoSpacing != null) return s.logoSpacing!;
    }
    return spacing;
  }

  /// Returns the effective top gradient height for this image (custom or global).
  double effectiveTopGradientHeight() {
    final s = imageSettings;
    if (s?.enabled == true) {
      if (s!.useGlobalGradientHeight && s.topGradientHeight != null) return s.topGradientHeight!;
      if (s.useTopGradientHeight && s.topGradientHeight != null) return s.topGradientHeight!;
    }
    return topGradientHeight ?? topLeftHeight;
  }

  /// Returns the effective bottom gradient height for this image (custom or global).
  double effectiveBottomGradientHeight() {
    final s = imageSettings;
    if (s?.enabled == true) {
      if (s!.useGlobalGradientHeight && s.bottomGradientHeight != null) return s.bottomGradientHeight!;
      if (s.useBottomGradientHeight && s.bottomGradientHeight != null) return s.bottomGradientHeight!;
    }
    return bottomGradientHeight ?? bottomHeight;
  }
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
    img.Image? o;
    final rw = s.rawWidth, rh = s.rawHeight;
    if (rw != null && rh != null) {
      // Raw pixels; an empty payload means "already pinned in the cache".
      if (s.bytes.length < rw * rh * 4) return null;
      o = imageFromRaw(rw, rh, s.bytes);
    } else {
      final d = img.decodeImage(s.bytes);
      if (d == null) return null;
      o = img.bakeOrientation(d);
    }
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

  // Use reference shortest side if provided (for consistent logo sizing across photos),
  // otherwise calculate from the current photo.
  final shortest = r.referenceShortestSide ??
      (photo.width < photo.height ? photo.width : photo.height).toDouble();

  // Gradually reduce logo size as aspect ratio increases (more horizontal).
  // 9:16 (0.5625) vertical = 1.0 (reference), 1:1 = ~0.9, 16:9 (1.777) = ~0.8
  final aspectRatio = photo.width / photo.height;
  const refAspect = 9 / 16; // 0.5625 - vertical reference
  final logoSizeFactor = (refAspect / aspectRatio).clamp(0.75, 1.0);

  // Draw top gradient if enabled.
  if (r.topGradient) {
    final gradHeight = (r.effectiveTopGradientHeight() * shortest).round().clamp(1, photo.height);
    final color = r.gradientColor;
    final opacity = r.gradientOpacity.clamp(0.0, 1.0);
    final rColor = (color >> 16) & 0xFF;
    final gColor = (color >> 8) & 0xFF;
    final bColor = color & 0xFF;
    _drawGradient(photo, top: 0, height: gradHeight, fromTop: true, colorR: rColor, colorG: gColor, colorB: bColor, opacity: opacity);
  }

  // Draw bottom gradient if enabled.
  if (r.bottomGradient) {
    final gradHeight = (r.effectiveBottomGradientHeight() * shortest).round().clamp(1, photo.height);
    final color = r.gradientColor;
    final opacity = r.gradientOpacity.clamp(0.0, 1.0);
    final rColor = (color >> 16) & 0xFF;
    final gColor = (color >> 8) & 0xFF;
    final bColor = color & 0xFF;
    _drawGradient(photo, top: photo.height - gradHeight, height: gradHeight, fromTop: false, colorR: rColor, colorG: gColor, colorB: bColor, opacity: opacity);
  }

  // Decode each distinct source only once per render.
  final local = <String, img.Image?>{};
  img.Image? decode(ImageSrc s) => local.putIfAbsent(s.key, () => load(s));

  // Per-row spacing (may differ if per-image settings override).
  final topGap = shortest * r.effectiveTopLeftSpacing();
  final bottomGap = shortest * r.effectiveBottomSpacing();

  // Corner section: rightmost 20% of photo width reserved for main corner logo.
  // Top row should not extend into this area.
  final cornerSectionLeft = (photo.width * 0.8).round().toDouble();

  // Top-left / top row (lowest layer). Always anchored to the left; only the
  // bottom row honors the "centered" option.
  final topH = (shortest * r.effectiveTopLeftHeight() * logoSizeFactor).roundToDouble();
  final topRowTop = shortest * r.effectiveTopLeftTop();
  final topRowStartX = shortest * r.effectiveTopLeftLeft();

  // Calculate corner logo position FIRST (if present) so top row can stop before it.
  // Corner logo uses the SAME height as top logos for consistent sizing.
  int cornerLogoLeftEdge = photo.width; // default: no corner logo, use full width
  if (r.cornerLogo != null) {
    final cornerLogoImg = decode(r.cornerLogo!);
    if (cornerLogoImg != null) {
      // Use same height as top logos (effectiveTopLeftHeight) for consistent sizing
      final cornerH = (shortest * r.effectiveTopLeftHeight() * logoSizeFactor).round().clamp(1, photo.height);
      final resizedCorner = _resize(cornerLogoImg, height: cornerH);
      final marginRight = (shortest * r.effectiveCornerMarginRight()).round();
      // Corner logo's left edge = photo.width - marginRight - cornerWidth
      cornerLogoLeftEdge = (photo.width - marginRight - resizedCorner!.width).round();
    }
  }

  // Top row stops before corner logo with a small gap (1% of shortest side)
  final gapToCorner = (shortest * 0.01).round();
  final topRowMaxX = (r.cornerLogo != null) ? (cornerLogoLeftEdge - gapToCorner) : cornerSectionLeft;

  _drawRow(
    photo,
    r.topLeftLogos,
    decode,
    height: topH,
    startX: topRowStartX,
    top: topRowTop,
    opacity: r.rowOpacity,
    gap: topGap,
    maxX: topRowMaxX.toDouble(),
  );

  // Extra logo for top-left row: below the leftmost logo.
  if (r.topLeftBottomLogo != null && r.topLeftLogos.isNotEmpty) {
    final logo = decode(r.topLeftBottomLogo!);
    if (logo != null) {
      final h = (shortest * r.effectiveTopLeftHeight() * logoSizeFactor).round().clamp(1, photo.height);
      final resized = _resize(logo, height: h);
      final margin = (shortest * r.topLeftBottomMargin).round();
      final x = topRowStartX.round();
      final y = topRowTop + topH + margin;
      if (y + h <= photo.height) img.compositeImage(photo, resized, dstX: x, dstY: y.toInt());
    }
  }

  // Bottom row.
  final bottomH = (shortest * r.effectiveBottomHeight() * logoSizeFactor).roundToDouble();
  final rowWidth = _rowWidth(r.bottomLogos, decode, bottomH, bottomGap);
  // Always center: allow negative startX so row stays centered even if wider than photo
  // (logos will be clipped on both sides symmetrically, not just left).
  final bottomStartX = r.centered
      ? (photo.width - rowWidth) / 2
      : shortest * r.effectiveBottomMargin();
  final bottomRowTop = photo.height - shortest * r.effectiveBottomMargin() - bottomH;
  _drawRow(
    photo,
    r.bottomLogos,
    decode,
    height: bottomH,
    startX: bottomStartX,
    top: bottomRowTop,
    opacity: r.rowOpacity,
    gap: bottomGap,
  );

  // Extra logos for bottom row: above leftmost and rightmost logos.
  // Use ACTUAL rendered positions (after clamping), not theoretical.
  // Reserve top-right corner area for the main corner logo (never overlap it).
  // Reserve ~20% of photo width from right edge as "corner section".
  final cornerLogo = r.cornerLogo;
  img.Image? decodedCorner;
  int cornerW = 0, cornerH = 0;
  // Corner section: rightmost 20% of photo width, top 20% of photo height
  final cornerSectionLeftInt = cornerSectionLeft.round();
  final cornerSectionTop = (photo.height * 0.2).round();
  if (cornerLogo != null) {
    decodedCorner = decode(cornerLogo);
    if (decodedCorner != null) {
      cornerH = (shortest * r.effectiveCornerHeight() * logoSizeFactor).round().clamp(1, photo.height);
      final resizedCorner = _resize(decodedCorner!, height: cornerH);
      cornerW = resizedCorner.width;
    }
  }
  // Helper: check if a logo rect overlaps the reserved corner section (20% from right/top)
  bool _overlapsCornerSection(int x, int y, int w, int h) {
    // Logo rect
    final lLeft = x;
    final lRight = x + w;
    final lTop = y;
    final lBottom = y + h;
    // Reserved corner section: right 20% width, top 20% height
    final cLeft = cornerSectionLeftInt;
    final cRight = photo!.width;
    final cTop = 0;
    final cBottom = cornerSectionTop;
    return !(lRight < cLeft || lLeft > cRight || lBottom < cTop || lTop > cBottom);
  }

  if (r.bottomLeftTopLogo != null && r.bottomLogos.isNotEmpty) {
    final logo = decode(r.bottomLeftTopLogo!);
    if (logo != null) {
      final h = (shortest * r.effectiveBottomHeight() * logoSizeFactor).round().clamp(1, photo.height);
      final resized = _resize(logo, height: h);
      final margin = (shortest * r.bottomLeftTopMargin).round();
      final x = bottomStartX.round(); // CLAMPED position
      final y = (bottomRowTop - margin - h).round();
      if (y >= 0 && !_overlapsCornerSection(x, y, resized!.width, resized.height)) {
        final dstY = y.clamp(0, photo.height - h).toInt();
        img.compositeImage(photo, resized, dstX: x, dstY: dstY);
      }
    }
  }
  if (r.bottomRightTopLogo != null && r.bottomLogos.isNotEmpty) {
    final logo = decode(r.bottomRightTopLogo!);
    if (logo != null) {
      final h = (shortest * r.effectiveBottomHeight() * logoSizeFactor).round().clamp(1, photo.height);
      final resized = _resize(logo, height: h);
      final margin = (shortest * r.bottomRightTopMargin).round();
      // Rightmost logo's actual X = clamped startX + actual rendered width - logo width
      // _drawRow stops at dst.width, so rendered width = min(rowWidth, photo.width - bottomStartX)
      final renderedRowWidth = math.min(rowWidth, photo.width - bottomStartX);
      final x = (bottomStartX + renderedRowWidth - resized!.width).round();
      final y = (bottomRowTop - margin - h).round();
      if (y >= 0 && !_overlapsCornerSection(x, y, resized!.width, resized.height)) {
        final dstY = y.clamp(0, photo.height - h).toInt();
        img.compositeImage(photo, resized, dstX: x, dstY: dstY);
      }
    }
  }

  // Top-right main logo.
  final corner = r.cornerLogo;
  if (corner != null) {
    final logo = decode(corner);
    if (logo != null) {
      // Use SAME height as top logos for consistent sizing
      final h = (shortest * r.effectiveTopLeftHeight() * logoSizeFactor).round().clamp(1, photo.height);
      final resized = _resize(logo, height: h);
      final marginTop = shortest * r.effectiveCornerMarginTop();
      final marginRight = shortest * r.effectiveCornerMarginRight();
      final x = (photo.width - marginRight - resized!.width).round();
      final y = marginTop.round();
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
    if (resized!.width > photo.width) {
      resized = _resize(text, width: photo.width);
    }
    final x = ((photo.width - resized!.width) / 2).round();
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
  double? maxX,
}) {
  if (logos.isEmpty) return;
  final h = height.round().clamp(1, dst.height);
  final y = top.round();
  // Clamp startX to valid range [0, dst.width)
  var x = startX.clamp(0.0, dst.width.toDouble() - 1);
  final limitX = maxX ?? dst.width.toDouble();
  for (final src in logos) {
    final logo = decode(src);
    if (logo == null) continue;
    final resized = _withOpacity(_resize(logo, height: h), opacity);
    final logoRight = x + resized!.width;
    // Only draw if logo fits fully within image bounds (with 1px tolerance) and before maxX
    if (logoRight <= dst.width + 1 && logoRight <= limitX + 1) {
      img.compositeImage(dst, resized, dstX: x.round(), dstY: y);
    }
    x = logoRight + gap;
    if (x >= dst.width || x >= limitX) break; // No more room for next logo
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

/// Draws a gradient-to-transparent linear gradient on [dst].
/// - [top]: starting Y coordinate of the gradient band.
/// - [height]: height of the gradient band in pixels.
/// - [fromTop]: if true, gradient goes from opaque at edge to transparent inward;
///   if false, gradient goes from transparent inward to opaque at edge.
/// - [colorR], [colorG], [colorB]: gradient color components (0-255).
/// - [opacity]: overall opacity multiplier (0.0 to 1.0).
void _drawGradient(
  img.Image dst, {
  required int top,
  required int height,
  required bool fromTop,
  required int colorR,
  required int colorG,
  required int colorB,
  required double opacity,
}) {
  if (height <= 0) return;
  final w = dst.width;
  final h = dst.height;
  final endY = (top + height).clamp(0, h);
  final opacityAlpha = (opacity * 255).round().clamp(0, 255);
  for (int y = top.clamp(0, h); y < endY; y++) {
    // Linear interpolation: 0.0 at transparent edge, 1.0 at opaque edge.
    final t = fromTop ? 1.0 - (y - top) / height : (y - top) / height;
    final alpha = (t * opacityAlpha).round().clamp(0, 255);
    if (alpha == 0) continue;
    for (int x = 0; x < w; x++) {
      final p = dst.getPixel(x, y);
      // Blend gradient color with alpha over existing pixel.
      final newR = (p.r * (255 - alpha) + colorR * alpha) ~/ 255;
      final newG = (p.g * (255 - alpha) + colorG * alpha) ~/ 255;
      final newB = (p.b * (255 - alpha) + colorB * alpha) ~/ 255;
      final newA = p.a + alpha - (p.a * alpha) ~/ 255;
      dst.setPixelRgba(x, y, newR, newG, newB, newA.clamp(0, 255));
    }
  }
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

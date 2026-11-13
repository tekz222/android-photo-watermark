import 'dart:typed_data';

/// A single logo in a row. [path] is an internal copy of the image; [sourceKey]
/// is the original file name (for name de-dup); [bytes] is the in-memory image
/// for rendering; [phash] is a perceptual hash for visual-similarity de-dup;
/// [phones] and [texts] are OCR-extracted phone numbers and normalized text
/// lines (e.g. company name) used to block logos of the same business.
class LogoItem {
  LogoItem(this.id, this.path, this.sourceKey, this.bytes, this.phash,
      this.phones, this.texts);

  final int id;
  final String path;
  final String sourceKey;
  final Uint8List bytes;
  final int phash;
  final Set<String> phones;
  final Set<String> texts;
}

/// Where a step's logos are placed, used to draw the little frame glyphs.
enum Placement { bottom, topLeft, topRight }

/// Where a picture attached to a text sits relative to the text.
enum TextImagePos { top, bottom, left, right, both, inside }

/// Export mode for project files.
enum ExportMode { settingsOnly, full }

/// Per-image custom logo settings. When enabled for an image, these override
/// the global logo size/margin settings for that specific image only.
class ImageSettings {
  ImageSettings({
    this.enabled = false,
    this.bottomLogoSize,
    this.bottomLogoMargin,
    this.topLeftLogoSize,
    this.topLeftLogoMarginTop,
    this.topLeftLogoMarginLeft,
    this.cornerLogoSize,
    this.cornerLogoMarginTop,
    this.cornerLogoMarginRight,
  });

  /// Whether custom settings are enabled for this image.
  final bool enabled;

  // Bottom row (base)
  final double? bottomLogoSize;    // fraction of shortest side (default: logoSize)
  final double? bottomLogoMargin;  // fraction of shortest side (default: bottomMargin)

  // Top-left row
  final double? topLeftLogoSize;       // fraction of shortest side (default: logoSize)
  final double? topLeftLogoMarginTop;  // fraction of shortest side (default: topMargin)
  final double? topLeftLogoMarginLeft; // fraction of shortest side (default: leftMargin)

  // Corner logo (top-right)
  final double? cornerLogoSize;        // fraction of shortest side (default: cornerHeight)
  final double? cornerLogoMarginTop;   // fraction of shortest side (default: cornerMarginTop)
  final double? cornerLogoMarginRight; // fraction of shortest side (default: cornerMarginRight)

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'bottomLogoSize': bottomLogoSize,
    'bottomLogoMargin': bottomLogoMargin,
    'topLeftLogoSize': topLeftLogoSize,
    'topLeftLogoMarginTop': topLeftLogoMarginTop,
    'topLeftLogoMarginLeft': topLeftLogoMarginLeft,
    'cornerLogoSize': cornerLogoSize,
    'cornerLogoMarginTop': cornerLogoMarginTop,
    'cornerLogoMarginRight': cornerLogoMarginRight,
  };

  static ImageSettings fromJson(Map<String, dynamic> json) => ImageSettings(
    enabled: json['enabled'] as bool? ?? false,
    bottomLogoSize: (json['bottomLogoSize'] as num?)?.toDouble(),
    bottomLogoMargin: (json['bottomLogoMargin'] as num?)?.toDouble(),
    topLeftLogoSize: (json['topLeftLogoSize'] as num?)?.toDouble(),
    topLeftLogoMarginTop: (json['topLeftLogoMarginTop'] as num?)?.toDouble(),
    topLeftLogoMarginLeft: (json['topLeftLogoMarginLeft'] as num?)?.toDouble(),
    cornerLogoSize: (json['cornerLogoSize'] as num?)?.toDouble(),
    cornerLogoMarginTop: (json['cornerLogoMarginTop'] as num?)?.toDouble(),
    cornerLogoMarginRight: (json['cornerLogoMarginRight'] as num?)?.toDouble(),
  );

  /// Returns a copy with the given fields updated.
  ImageSettings copyWith({
    bool? enabled,
    double? bottomLogoSize,
    double? bottomLogoMargin,
    double? topLeftLogoSize,
    double? topLeftLogoMarginTop,
    double? topLeftLogoMarginLeft,
    double? cornerLogoSize,
    double? cornerLogoMarginTop,
    double? cornerLogoMarginRight,
  }) => ImageSettings(
    enabled: enabled ?? this.enabled,
    bottomLogoSize: bottomLogoSize ?? this.bottomLogoSize,
    bottomLogoMargin: bottomLogoMargin ?? this.bottomLogoMargin,
    topLeftLogoSize: topLeftLogoSize ?? this.topLeftLogoSize,
    topLeftLogoMarginTop: topLeftLogoMarginTop ?? this.topLeftLogoMarginTop,
    topLeftLogoMarginLeft: topLeftLogoMarginLeft ?? this.topLeftLogoMarginLeft,
    cornerLogoSize: cornerLogoSize ?? this.cornerLogoSize,
    cornerLogoMarginTop: cornerLogoMarginTop ?? this.cornerLogoMarginTop,
    cornerLogoMarginRight: cornerLogoMarginRight ?? this.cornerLogoMarginRight,
  );
}

/// An editable text overlay. Always centered horizontally on the photo; the
/// user picks the vertical position ([topPct]) and the size ([heightPct]),
/// both as percentages of the photo. Mutable on purpose: the editor changes
/// fields in place and the preview re-renders.
class TextItem {
  TextItem({
    required this.id,
    this.text = 'Seu texto',
    this.fontFamily = 'Arial',
    this.bold = true,
    this.italic = false,
    this.color = 0xFFFFFFFF,
    this.rainbow = false,
    this.gradientColors = const [0xFFFFFFFF, 0xFF000000],
    this.gradientStops = const [0.0, 1.0],
    this.gradientAngle = 0.0, // 0 = horizontal, 90 = vertical
    this.outline = true,
    this.outlineColor = 0xFF000000,
    this.outlineWidth = 8, // stroke width as % of the font size
    this.heightPct = 10, // text height as % of the photo's shortest side
    this.topPct = 77, // vertical center as % of the photo height
    this.curve = 0, // arc angle in degrees: 0 = straight, >0 arc up, <0 arc down
    this.imageBytes,
    this.imageName,
    this.imageSig = 0,
    this.imagePos = TextImagePos.left,
    this.imageSize = 100, // picture height as % of the text height
    this.imageGap = 15, // gap between picture and text as % of the text height
  });

  final int id;
  String text;
  String fontFamily;
  bool bold;
  bool italic;
  int color; // ARGB (used when rainbow=false and gradientColors not set)
  bool rainbow; // rainbow gradient fill (overrides [color] and [gradientColors])
  List<int> gradientColors; // ARGB colors for custom gradient (2-3 colors)
  List<double> gradientStops; // gradient stops (0.0 to 1.0), same length as gradientColors
  double gradientAngle; // gradient angle in degrees (0 = left-to-right, 90 = top-to-bottom)
  bool outline;
  int outlineColor; // ARGB
  double outlineWidth;
  double heightPct;
  double topPct;
  double curve;

  /// Optional picture drawn together with the text (the whole block stays
  /// horizontally centered on the photo).
  Uint8List? imageBytes;
  String? imageName;
  int imageSig; // cheap identity of [imageBytes], for cache invalidation
  TextImagePos imagePos;
  double imageSize;
  double imageGap;

  bool get useCustomGradient => !rainbow && gradientColors.length >= 2;
}

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

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'sourceKey': sourceKey,
    'bytes': bytes, // Note: bytes not serialized in project (too large), path used instead
    'phash': phash,
    'phones': phones.toList(),
    'texts': texts.toList(),
  };

  static LogoItem fromJson(Map<String, dynamic> json) => LogoItem(
    json['id'] as int,
    json['path'] as String,
    json['sourceKey'] as String,
    Uint8List.fromList((json['bytes'] as List? ?? []).cast<int>()), // bytes loaded from path at runtime
    json['phash'] as int? ?? 0,
    (json['phones'] as List? ?? []).cast<String>().toSet(),
    (json['texts'] as List? ?? []).cast<String>().toSet(),
  );
}

/// Where a step's logos are placed, used to draw the little frame glyphs.
enum Placement { bottom, topLeft, topRight }

/// Where a picture attached to a text sits relative to the text.
enum TextImagePos { top, bottom, left, right, both, inside }

/// How logo sets are assigned to photos.
enum LogoSetMode { single, alternating, alternating3 }

/// A complete logo set (bottom row, top-left row). Corner logo is shared globally.
class LogoSet {
  LogoSet({
    required this.bottomLogos,
    required this.topLeftLogos,
    // Bottom row: extra logos above leftmost and rightmost
    this.bottomLeftTopLogo,
    this.bottomRightTopLogo,
    // Top-left row: extra logo below leftmost
    this.topLeftBottomLogo,
    // Margin for extra bottom logos (fraction of shortest side)
    this.bottomLeftTopMargin = 2.0,
    this.bottomRightTopMargin = 2.0,
    // Margin for extra top logo (fraction of shortest side)
    this.topLeftBottomMargin = 2.0,
  });

  final List<LogoItem> bottomLogos;
  final List<LogoItem> topLeftLogos;

  // Extra logos for bottom row (placed above the main row)
  final LogoItem? bottomLeftTopLogo;   // Above leftmost bottom logo
  final LogoItem? bottomRightTopLogo;  // Above rightmost bottom logo

  // Extra logo for top-left row (placed below the main row)
  final LogoItem? topLeftBottomLogo;   // Below leftmost top-left logo

  // Margins for extra logos (distance from main row)
  final double bottomLeftTopMargin;
  final double bottomRightTopMargin;
  final double topLeftBottomMargin;

  Map<String, dynamic> toJson() => {
    'bottomLogos': bottomLogos.map((e) => e.toJson()).toList(),
    'topLeftLogos': topLeftLogos.map((e) => e.toJson()).toList(),
    'bottomLeftTopLogo': bottomLeftTopLogo?.toJson(),
    'bottomRightTopLogo': bottomRightTopLogo?.toJson(),
    'topLeftBottomLogo': topLeftBottomLogo?.toJson(),
    'bottomLeftTopMargin': bottomLeftTopMargin,
    'bottomRightTopMargin': bottomRightTopMargin,
    'topLeftBottomMargin': topLeftBottomMargin,
  };

  static LogoSet fromJson(Map<String, dynamic> json) => LogoSet(
    bottomLogos: (json['bottomLogos'] as List? ?? [])
        .map((e) => LogoItem.fromJson(e)).toList(),
    topLeftLogos: (json['topLeftLogos'] as List? ?? [])
        .map((e) => LogoItem.fromJson(e)).toList(),
    bottomLeftTopLogo: json['bottomLeftTopLogo'] != null
        ? LogoItem.fromJson(json['bottomLeftTopLogo'] as Map<String, dynamic>)
        : null,
    bottomRightTopLogo: json['bottomRightTopLogo'] != null
        ? LogoItem.fromJson(json['bottomRightTopLogo'] as Map<String, dynamic>)
        : null,
    topLeftBottomLogo: json['topLeftBottomLogo'] != null
        ? LogoItem.fromJson(json['topLeftBottomLogo'] as Map<String, dynamic>)
        : null,
    bottomLeftTopMargin: (json['bottomLeftTopMargin'] as num?)?.toDouble() ?? 2.0,
    bottomRightTopMargin: (json['bottomRightTopMargin'] as num?)?.toDouble() ?? 2.0,
    topLeftBottomMargin: (json['topLeftBottomMargin'] as num?)?.toDouble() ?? 2.0,
  );

  LogoSet copyWith({
    List<LogoItem>? bottomLogos,
    List<LogoItem>? topLeftLogos,
    LogoItem? bottomLeftTopLogo,
    LogoItem? bottomRightTopLogo,
    LogoItem? topLeftBottomLogo,
    double? bottomLeftTopMargin,
    double? bottomRightTopMargin,
    double? topLeftBottomMargin,
    // Use special sentinel to clear optional logos
    bool clearBottomLeftTopLogo = false,
    bool clearBottomRightTopLogo = false,
    bool clearTopLeftBottomLogo = false,
  }) => LogoSet(
    bottomLogos: bottomLogos ?? this.bottomLogos,
    topLeftLogos: topLeftLogos ?? this.topLeftLogos,
    bottomLeftTopLogo: clearBottomLeftTopLogo ? null : (bottomLeftTopLogo ?? this.bottomLeftTopLogo),
    bottomRightTopLogo: clearBottomRightTopLogo ? null : (bottomRightTopLogo ?? this.bottomRightTopLogo),
    topLeftBottomLogo: clearTopLeftBottomLogo ? null : (topLeftBottomLogo ?? this.topLeftBottomLogo),
    bottomLeftTopMargin: bottomLeftTopMargin ?? this.bottomLeftTopMargin,
    bottomRightTopMargin: bottomRightTopMargin ?? this.bottomRightTopMargin,
    topLeftBottomMargin: topLeftBottomMargin ?? this.topLeftBottomMargin,
  );
}

/// Export mode for project files.
enum ExportMode { settingsOnly, full }

/// Per-image custom logo settings. When enabled for an image, these override
/// the global logo size/margin settings for that specific image only.
class ImageSettings {
  ImageSettings({
    this.enabled = false,
    // Logo size overrides
    this.bottomLogoSize,
    this.topLeftLogoSize,
    this.cornerLogoSize,
    // Margin overrides
    this.bottomLogoMargin,
    this.topLeftLogoMarginTop,
    this.topLeftLogoMarginLeft,
    this.cornerLogoMarginRight,
    // Spacing override
    this.logoSpacing,
    // Gradient height overrides
    this.topGradientHeight,
    this.bottomGradientHeight,
    // Boolean flags for logo size override groups
    this.useGlobalLogoSize = false,
    this.useBottomLogoSize = false,
    this.useTopLeftLogoSize = false,
    this.useCornerLogoSize = false,
    // Boolean flags for spacing override groups
    this.useGlobalSpacing = false,
    this.useBottomSpacing = false,
    this.useTopLeftSpacing = false,
    // Boolean flags for gradient height override groups
    this.useGlobalGradientHeight = false,
    this.useTopGradientHeight = false,
    this.useBottomGradientHeight = false,
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
  final double? cornerLogoMarginRight; // fraction of shortest side (default: cornerMarginRight)

  // Spacing between logos in a row
  final double? logoSpacing; // fraction of shortest side (default: logoSpacing)

  // Gradient heights
  final double? topGradientHeight;    // fraction of shortest side (default: topGradientHeight)
  final double? bottomGradientHeight; // fraction of shortest side (default: bottomGradientHeight)

  // Boolean flags for logo size override groups
  /// If true, use global [logoSize] for all sections (bottom, top-left, corner).
  final bool useGlobalLogoSize;
  /// If true, use per-image [bottomLogoSize] for bottom row.
  final bool useBottomLogoSize;
  /// If true, use per-image [topLeftLogoSize] for top-left row.
  final bool useTopLeftLogoSize;
  /// If true, use per-image [cornerLogoSize] for corner logo.
  final bool useCornerLogoSize;

  // Boolean flags for spacing override groups
  /// If true, use global [logoSpacing] for all sections.
  final bool useGlobalSpacing;
  /// If true, use per-image [logoSpacing] for bottom row.
  final bool useBottomSpacing;
  /// If true, use per-image [logoSpacing] for top-left row.
  final bool useTopLeftSpacing;

  // Boolean flags for gradient height override groups
  /// If true, use global [topGradientHeight]/[bottomGradientHeight] for both gradients.
  final bool useGlobalGradientHeight;
  /// If true, use per-image [topGradientHeight] for top gradient.
  final bool useTopGradientHeight;
  /// If true, use per-image [bottomGradientHeight] for bottom gradient.
  final bool useBottomGradientHeight;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'bottomLogoSize': bottomLogoSize,
    'bottomLogoMargin': bottomLogoMargin,
    'topLeftLogoSize': topLeftLogoSize,
    'topLeftLogoMarginTop': topLeftLogoMarginTop,
    'topLeftLogoMarginLeft': topLeftLogoMarginLeft,
    'cornerLogoSize': cornerLogoSize,
    'cornerLogoMarginRight': cornerLogoMarginRight,
    'logoSpacing': logoSpacing,
    'topGradientHeight': topGradientHeight,
    'bottomGradientHeight': bottomGradientHeight,
    'useGlobalLogoSize': useGlobalLogoSize,
    'useBottomLogoSize': useBottomLogoSize,
    'useTopLeftLogoSize': useTopLeftLogoSize,
    'useCornerLogoSize': useCornerLogoSize,
    'useGlobalSpacing': useGlobalSpacing,
    'useBottomSpacing': useBottomSpacing,
    'useTopLeftSpacing': useTopLeftSpacing,
    'useGlobalGradientHeight': useGlobalGradientHeight,
    'useTopGradientHeight': useTopGradientHeight,
    'useBottomGradientHeight': useBottomGradientHeight,
  };

  static ImageSettings fromJson(Map<String, dynamic> json) => ImageSettings(
    enabled: json['enabled'] as bool? ?? false,
    bottomLogoSize: (json['bottomLogoSize'] as num?)?.toDouble(),
    bottomLogoMargin: (json['bottomLogoMargin'] as num?)?.toDouble(),
    topLeftLogoSize: (json['topLeftLogoSize'] as num?)?.toDouble(),
    topLeftLogoMarginTop: (json['topLeftLogoMarginTop'] as num?)?.toDouble(),
    topLeftLogoMarginLeft: (json['topLeftLogoMarginLeft'] as num?)?.toDouble(),
    cornerLogoSize: (json['cornerLogoSize'] as num?)?.toDouble(),
    cornerLogoMarginRight: (json['cornerLogoMarginRight'] as num?)?.toDouble(),
    logoSpacing: (json['logoSpacing'] as num?)?.toDouble(),
    topGradientHeight: (json['topGradientHeight'] as num?)?.toDouble(),
    bottomGradientHeight: (json['bottomGradientHeight'] as num?)?.toDouble(),
    useGlobalLogoSize: json['useGlobalLogoSize'] as bool? ?? false,
    useBottomLogoSize: json['useBottomLogoSize'] as bool? ?? false,
    useTopLeftLogoSize: json['useTopLeftLogoSize'] as bool? ?? false,
    useCornerLogoSize: json['useCornerLogoSize'] as bool? ?? false,
    useGlobalSpacing: json['useGlobalSpacing'] as bool? ?? false,
    useBottomSpacing: json['useBottomSpacing'] as bool? ?? false,
    useTopLeftSpacing: json['useTopLeftSpacing'] as bool? ?? false,
    useGlobalGradientHeight: json['useGlobalGradientHeight'] as bool? ?? false,
    useTopGradientHeight: json['useTopGradientHeight'] as bool? ?? false,
    useBottomGradientHeight: json['useBottomGradientHeight'] as bool? ?? false,
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
    double? cornerLogoMarginRight,
    double? logoSpacing,
    double? topGradientHeight,
    double? bottomGradientHeight,
    bool? useGlobalLogoSize,
    bool? useBottomLogoSize,
    bool? useTopLeftLogoSize,
    bool? useCornerLogoSize,
    bool? useGlobalSpacing,
    bool? useBottomSpacing,
    bool? useTopLeftSpacing,
    bool? useGlobalGradientHeight,
    bool? useTopGradientHeight,
    bool? useBottomGradientHeight,
  }) => ImageSettings(
    enabled: enabled ?? this.enabled,
    bottomLogoSize: bottomLogoSize ?? this.bottomLogoSize,
    bottomLogoMargin: bottomLogoMargin ?? this.bottomLogoMargin,
    topLeftLogoSize: topLeftLogoSize ?? this.topLeftLogoSize,
    topLeftLogoMarginTop: topLeftLogoMarginTop ?? this.topLeftLogoMarginTop,
    topLeftLogoMarginLeft: topLeftLogoMarginLeft ?? this.topLeftLogoMarginLeft,
    cornerLogoSize: cornerLogoSize ?? this.cornerLogoSize,
    cornerLogoMarginRight: cornerLogoMarginRight ?? this.cornerLogoMarginRight,
    logoSpacing: logoSpacing ?? this.logoSpacing,
    topGradientHeight: topGradientHeight ?? this.topGradientHeight,
    bottomGradientHeight: bottomGradientHeight ?? this.bottomGradientHeight,
    useGlobalLogoSize: useGlobalLogoSize ?? this.useGlobalLogoSize,
    useBottomLogoSize: useBottomLogoSize ?? this.useBottomLogoSize,
    useTopLeftLogoSize: useTopLeftLogoSize ?? this.useTopLeftLogoSize,
    useCornerLogoSize: useCornerLogoSize ?? this.useCornerLogoSize,
    useGlobalSpacing: useGlobalSpacing ?? this.useGlobalSpacing,
    useBottomSpacing: useBottomSpacing ?? this.useBottomSpacing,
    useTopLeftSpacing: useTopLeftSpacing ?? this.useTopLeftSpacing,
    useGlobalGradientHeight: useGlobalGradientHeight ?? this.useGlobalGradientHeight,
    useTopGradientHeight: useTopGradientHeight ?? this.useTopGradientHeight,
    useBottomGradientHeight: useBottomGradientHeight ?? this.useBottomGradientHeight,
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
    this.customFontPath,
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

  /// Path to a custom font file (.ttf/.otf) loaded by the user.
  /// If set, this font will be used instead of [fontFamily].
  String? customFontPath;

  bool get useCustomGradient => !rainbow && gradientColors.length >= 2;
}

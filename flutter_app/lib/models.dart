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
enum TextImagePos { top, bottom, left, right, inside }

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
    this.outline = true,
    this.outlineColor = 0xFF000000,
    this.outlineWidth = 8, // stroke width as % of the font size
    this.heightPct = 10, // text height as % of the photo's shortest side
    this.topPct = 50, // vertical center as % of the photo height
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
  int color; // ARGB
  bool rainbow; // rainbow gradient fill (overrides [color])
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
}

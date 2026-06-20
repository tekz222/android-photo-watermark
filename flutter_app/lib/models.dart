import 'dart:typed_data';

/// A single logo in a row. [path] is an internal copy of the image; [sourceKey]
/// is the original file name (for name de-dup); [bytes] is the in-memory image
/// for rendering; [phash] is a perceptual hash for visual-similarity de-dup.
class LogoItem {
  LogoItem(this.id, this.path, this.sourceKey, this.bytes, this.phash);

  final int id;
  final String path;
  final String sourceKey;
  final Uint8List bytes;
  final int phash;
}

/// Where a step's logos are placed, used to draw the little frame glyphs.
enum Placement { bottom, topLeft, topRight }

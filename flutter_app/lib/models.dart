import 'dart:typed_data';

/// A single logo in a row. [path] is an internal copy of the image (survives
/// app restarts); [sourceKey] is the original picked path, used to keep the same
/// logo out of both rows. [bytes] is the in-memory image for rendering.
class LogoItem {
  LogoItem(this.id, this.path, this.sourceKey, this.bytes);

  final int id;
  final String path;
  final String sourceKey;
  final Uint8List bytes;
}

/// Where a step's logos are placed, used to draw the little frame glyphs.
enum Placement { bottom, topLeft, topRight }

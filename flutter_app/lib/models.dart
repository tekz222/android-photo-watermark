import 'dart:typed_data';

/// A single logo in a row. Each entry has a unique [id] so the same image can be
/// added several times while still being individually removable/reorderable.
class LogoItem {
  LogoItem(this.id, this.bytes);

  final int id;
  final Uint8List bytes;
}

/// Where a step's logos are placed, used to draw the little frame glyphs.
enum Placement { bottom, topLeft, topRight }

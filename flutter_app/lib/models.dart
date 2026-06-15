import 'dart:typed_data';

/// A single logo in a row. Each entry has a unique [id] so the same image can be
/// added several times while still being individually removable/reorderable.
/// [path] identifies the source file, used to keep a logo from being in both the
/// bottom and the top rows at once.
class LogoItem {
  LogoItem(this.id, this.path, this.bytes);

  final int id;
  final String path;
  final Uint8List bytes;
}

/// Where a step's logos are placed, used to draw the little frame glyphs.
enum Placement { bottom, topLeft, topRight }

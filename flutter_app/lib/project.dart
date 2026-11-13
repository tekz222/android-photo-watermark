import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'watermark_engine.dart';

/// A rendered preview plus its aspect ratio, so its frame can match the image.
class Preview {
  Preview(this.bytes, this.aspect);
  final Uint8List bytes;
  final double aspect; // width / height
}

/// A single watermarking project with all its state.
class Project {
  Project({
    required this.id,
    required this.name,
    this.photoPaths = const [],
    this.bottomLogos = const [],
    this.topLeftLogos = const [],
    this.cornerLogo,
    this.texts = const [],
    this.textImagePath = const {},
    this.logoSize = 22.0,
    this.leftMargin = 1.0,
    this.logoOpacity = 90.0,
    this.bottomMargin = 2.0,
    this.topMargin = 2.0,
    this.cornerHeight = 22.0,
    this.cornerMarginTop = 2.0,
    this.cornerMarginRight = 2.0,
    this.centered = false,
    this.logoSpacing = 0.0,
    this.bottomGradient = false,
    this.topGradient = false,
    this.topGradientHeight = 22.0,
    this.bottomGradientHeight = 22.0,
    this.gradientColor = 0xFF000000,
    this.gradientOpacity = 1.0,
    this.savedPaths = const {},
    this.currentAlbum,
    this.lastResult,
    this.processing = false,
    this.cancelRequested = false,
    this.done = 0,
    this.total = 0,
    this.previewIndex = 0,
    this.previewVersion = 0,
    this.previewToken = 0,
    this.textTemplate,
    this.textSrc = const {},
    this.textRatio = const {},
    this.textSigCache = const {},
    this.previews = const {},
    this.renderedVersion = const {},
    this.previewFailed = const {},
    this.previewPhoto = const {},
    this.previewLogo = const {},
  }) : textJob = Future<void>.value();

  final String id;
  String name;
  final List<String> photoPaths;
  final List<LogoItem> bottomLogos;
  final List<LogoItem> topLeftLogos;
  LogoItem? cornerLogo;
  final List<TextItem> texts;
  Map<int, String> textImagePath;

  // Settings
  double logoSize;
  double leftMargin;
  double logoOpacity;
  double bottomMargin;
  double topMargin;
  double cornerHeight;
  double cornerMarginTop;
  double cornerMarginRight;
  bool centered;
  double logoSpacing;
  bool bottomGradient;
  bool topGradient;
  double topGradientHeight;
  double bottomGradientHeight;
  int gradientColor;
  double gradientOpacity;

  // Save state
  final Set<String> savedPaths;
  String? currentAlbum;
  ProcessResult? lastResult;
  bool processing;
  bool cancelRequested;
  int done;
  int total;

  // Preview state
  int previewIndex;
  int previewVersion;
  int previewToken;

  // Text caches
  Map<String, dynamic>? textTemplate;
  Map<int, ImageSrc> textSrc;
  Map<int, double> textRatio;
  Map<int, String> textSigCache;

  // Preview caches (mutable maps that persist across saves)
  Map<String, Preview> previews;
  Map<String, int> renderedVersion;
  Set<String> previewFailed;
  Map<String, Uint8List> previewPhoto;
  Map<int, Uint8List> previewLogo;
  Future<void>? textJob;

  /// Creates a copy of this project's settings (logos, texts, gradients, sliders)
  /// but with empty photos and save state.
  Project copySettingsOnly({String? newName}) {
    return Project(
      id: generateId(),
      name: newName ?? '$name (cópia)',
      // Empty photos for new project
      photoPaths: [],
      // Copy logos (new instances with same bytes)
      bottomLogos: bottomLogos.map((l) => LogoItem(
        nextLogoId(), l.path, l.sourceKey, l.bytes, l.phash, l.phones, l.texts)).toList(),
      topLeftLogos: topLeftLogos.map((l) => LogoItem(
        nextLogoId(), l.path, l.sourceKey, l.bytes, l.phash, l.phones, l.texts)).toList(),
      cornerLogo: cornerLogo != null ? LogoItem(
        nextLogoId(), cornerLogo!.path, cornerLogo!.sourceKey, cornerLogo!.bytes,
        cornerLogo!.phash, cornerLogo!.phones, cornerLogo!.texts) : null,
      // Copy texts
      texts: texts.map((t) => TextItem(
        id: nextTextId(),
        text: t.text,
        fontFamily: t.fontFamily,
        bold: t.bold,
        italic: t.italic,
        color: t.color,
        rainbow: t.rainbow,
        gradientColors: List<int>.from(t.gradientColors),
        gradientStops: List<double>.from(t.gradientStops),
        gradientAngle: t.gradientAngle,
        outline: t.outline,
        outlineColor: t.outlineColor,
        outlineWidth: t.outlineWidth,
        heightPct: t.heightPct,
        topPct: t.topPct,
        curve: t.curve,
        imageBytes: t.imageBytes,
        imageName: t.imageName,
        imageSig: t.imageSig,
        imagePos: t.imagePos,
        imageSize: t.imageSize,
        imageGap: t.imageGap,
      )).toList(),
      textImagePath: {}, // Will be re-rasterized
      // Copy all settings
      logoSize: logoSize,
      leftMargin: leftMargin,
      logoOpacity: logoOpacity,
      bottomMargin: bottomMargin,
      topMargin: topMargin,
      cornerHeight: cornerHeight,
      cornerMarginTop: cornerMarginTop,
      cornerMarginRight: cornerMarginRight,
      centered: centered,
      logoSpacing: logoSpacing,
      bottomGradient: bottomGradient,
      topGradient: topGradient,
      topGradientHeight: topGradientHeight,
      bottomGradientHeight: bottomGradientHeight,
      gradientColor: gradientColor,
      gradientOpacity: gradientOpacity,
      // Empty save state
      savedPaths: {},
      currentAlbum: null,
      lastResult: null,
      processing: false,
      cancelRequested: false,
      done: 0,
      total: 0,
      previewIndex: 0,
      previewVersion: 0,
      previewToken: 0,
      textTemplate: textTemplate,
      textSrc: {},
      textRatio: {},
      textSigCache: {},
      previews: {},
      renderedVersion: {},
      previewFailed: {},
      previewPhoto: {},
      previewLogo: {},
    );
  }

  /// Serializes project to JSON for persistence.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'photoPaths': photoPaths,
      'bottomLogos': bottomLogos.map(_logoToJson).toList(),
      'topLeftLogos': topLeftLogos.map(_logoToJson).toList(),
      'cornerLogo': cornerLogo != null ? _logoToJson(cornerLogo!) : null,
      'texts': texts.map(_textToJson).toList(),
      'textImagePath': textImagePath.map((k, v) => MapEntry(k.toString(), v)),
      'logoSize': logoSize,
      'leftMargin': leftMargin,
      'logoOpacity': logoOpacity,
      'bottomMargin': bottomMargin,
      'topMargin': topMargin,
      'cornerHeight': cornerHeight,
      'cornerMarginTop': cornerMarginTop,
      'cornerMarginRight': cornerMarginRight,
      'centered': centered,
      'logoSpacing': logoSpacing,
      'bottomGradient': bottomGradient,
      'topGradient': topGradient,
      'topGradientHeight': topGradientHeight,
      'bottomGradientHeight': bottomGradientHeight,
      'gradientColor': gradientColor,
      'gradientOpacity': gradientOpacity,
      'savedPaths': savedPaths.toList(),
      'currentAlbum': currentAlbum,
      'lastResult': lastResult != null ? {
        'saved': lastResult!.saved,
        'failed': lastResult!.failed,
        'album': lastResult!.album,
      } : null,
      'processing': processing,
      'cancelRequested': cancelRequested,
      'done': done,
      'total': total,
      'previewIndex': previewIndex,
      'previewVersion': previewVersion,
      'previewToken': previewToken,
      'textTemplate': textTemplate,
    };
  }

  /// Creates a Project from JSON.
  static Future<Project> fromJson(Map<String, dynamic> json) async {
    final bottomLogos = <LogoItem>[];
    for (final m in (json['bottomLogos'] as List? ?? [])) {
      final l = await _logoFromJson(m as Map<String, dynamic>);
      if (l != null) bottomLogos.add(l);
    }

    final topLeftLogos = <LogoItem>[];
    for (final m in (json['topLeftLogos'] as List? ?? [])) {
      final l = await _logoFromJson(m as Map<String, dynamic>);
      if (l != null) topLeftLogos.add(l);
    }

    LogoItem? cornerLogo;
    if (json['cornerLogo'] is Map) {
      cornerLogo = await _logoFromJson(json['cornerLogo'] as Map<String, dynamic>);
    }

    final texts = <TextItem>[];
    for (final tJson in (json['texts'] as List? ?? [])) {
      final t = await _textFromJson(tJson as Map<String, dynamic>);
      texts.add(t);
    }

    final textImagePath = <int, String>{};
    for (final entry in (json['textImagePath'] as Map? ?? {}).entries) {
      textImagePath[int.parse(entry.key)] = entry.value as String;
    }

    ProcessResult? lastResult;
    if (json['lastResult'] is Map) {
      final r = json['lastResult'] as Map<String, dynamic>;
      lastResult = ProcessResult(
        saved: r['saved'] as int,
        failed: r['failed'] as int,
        album: r['album'] as String,
      );
    }

    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      photoPaths: List<String>.from(json['photoPaths'] as List? ?? []),
      bottomLogos: bottomLogos,
      topLeftLogos: topLeftLogos,
      cornerLogo: cornerLogo,
      texts: texts,
      textImagePath: textImagePath,
      logoSize: (json['logoSize'] as num?)?.toDouble() ?? 22.0,
      leftMargin: (json['leftMargin'] as num?)?.toDouble() ?? 1.0,
      logoOpacity: (json['logoOpacity'] as num?)?.toDouble() ?? 90.0,
      bottomMargin: (json['bottomMargin'] as num?)?.toDouble() ?? 2.0,
      topMargin: (json['topMargin'] as num?)?.toDouble() ?? 2.0,
      cornerHeight: (json['cornerHeight'] as num?)?.toDouble() ?? 22.0,
      cornerMarginTop: (json['cornerMarginTop'] as num?)?.toDouble() ?? 2.0,
      cornerMarginRight: (json['cornerMarginRight'] as num?)?.toDouble() ?? 2.0,
      centered: json['centered'] as bool? ?? false,
      logoSpacing: (json['logoSpacing'] as num?)?.toDouble() ?? 0.0,
      bottomGradient: json['bottomGradient'] as bool? ?? false,
      topGradient: json['topGradient'] as bool? ?? false,
      topGradientHeight: (json['topGradientHeight'] as num?)?.toDouble() ?? 22.0,
      bottomGradientHeight: (json['bottomGradientHeight'] as num?)?.toDouble() ?? 22.0,
      gradientColor: (json['gradientColor'] as num?)?.toInt() ?? 0xFF000000,
      gradientOpacity: (json['gradientOpacity'] as num?)?.toDouble() ?? 1.0,
      savedPaths: Set<String>.from(json['savedPaths'] as List? ?? []),
      currentAlbum: json['currentAlbum'] as String?,
      lastResult: lastResult,
      processing: json['processing'] as bool? ?? false,
      cancelRequested: json['cancelRequested'] as bool? ?? false,
      done: json['done'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      previewIndex: json['previewIndex'] as int? ?? 0,
      previewVersion: json['previewVersion'] as int? ?? 0,
      previewToken: json['previewToken'] as int? ?? 0,
      textTemplate: json['textTemplate'] as Map<String, dynamic>?,
    );
  }

  static Map<String, dynamic> _logoToJson(LogoItem l) => {
    'path': l.path,
    'name': l.sourceKey,
    'bytes': base64Encode(l.bytes),
    'phash': l.phash,
    'phones': l.phones.toList(),
    'texts': l.texts.toList(),
  };

  static Future<LogoItem?> _logoFromJson(Map<String, dynamic> m) async {
    final path = m['path'] as String?;
    if (path == null) return null;
    // If bytes are stored in JSON, use them; otherwise read from file
    Uint8List bytes;
    if (m['bytes'] is String) {
      bytes = base64Decode(m['bytes'] as String);
    } else {
      final f = File(path);
      if (!f.existsSync()) return null;
      bytes = await f.readAsBytes();
    }
    return LogoItem(
      nextLogoId(),
      path,
      m['name'] as String? ?? '',
      bytes,
      (m['phash'] as num?)?.toInt() ?? imageSig(bytes),
      Set<String>.from(m['phones'] as List? ?? []),
      Set<String>.from(m['texts'] as List? ?? []),
    );
  }

  static Map<String, dynamic> _textToJson(TextItem t) => {
    'id': t.id,
    'text': t.text,
    'fontFamily': t.fontFamily,
    'bold': t.bold,
    'italic': t.italic,
    'color': t.color,
    'rainbow': t.rainbow,
    'gradientColors': t.gradientColors,
    'gradientStops': t.gradientStops,
    'gradientAngle': t.gradientAngle,
    'outline': t.outline,
    'outlineColor': t.outlineColor,
    'outlineWidth': t.outlineWidth,
    'heightPct': t.heightPct,
    'topPct': t.topPct,
    'curve': t.curve,
    'imageBytes': t.imageBytes != null ? base64Encode(t.imageBytes!) : null,
    'imageName': t.imageName,
    'imageSig': t.imageSig,
    'imagePos': t.imagePos.index,
    'imageSize': t.imageSize,
    'imageGap': t.imageGap,
  };

  static Future<TextItem> _textFromJson(Map<String, dynamic> m) async {
    Uint8List? imageBytes;
    if (m['imageBytes'] is String) {
      imageBytes = base64Decode(m['imageBytes'] as String);
    }
    return TextItem(
      id: m['id'] as int,
      text: m['text'] as String? ?? '',
      fontFamily: m['fontFamily'] as String? ?? 'Arial',
      bold: m['bold'] as bool? ?? true,
      italic: m['italic'] as bool? ?? false,
      color: (m['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
      rainbow: m['rainbow'] as bool? ?? false,
      gradientColors: (m['gradientColors'] as List?)?.cast<int>() ?? [0xFFFFFFFF, 0xFF000000],
      gradientStops: (m['gradientStops'] as List?)?.cast<double>() ?? [0.0, 1.0],
      gradientAngle: (m['gradientAngle'] as num?)?.toDouble() ?? 0.0,
      outline: m['outline'] as bool? ?? true,
      outlineColor: (m['outlineColor'] as num?)?.toInt() ?? 0xFF000000,
      outlineWidth: (m['outlineWidth'] as num?)?.toDouble() ?? 8.0,
      heightPct: (m['heightPct'] as num?)?.toDouble() ?? 10.0,
      topPct: (m['topPct'] as num?)?.toDouble() ?? 77.0,
      curve: (m['curve'] as num?)?.toDouble() ?? 0.0,
      imageBytes: imageBytes,
      imageName: m['imageName'] as String?,
      imageSig: (m['imageSig'] as num?)?.toInt() ?? 0,
      imagePos: TextImagePos.values[(m['imagePos'] as num?)?.toInt() ?? 2],
      imageSize: (m['imageSize'] as num?)?.toDouble() ?? 100.0,
      imageGap: (m['imageGap'] as num?)?.toDouble() ?? 15.0,
    );
  }

  static int nextLogoId() => DateTime.now().microsecondsSinceEpoch + _logoIdCounter++;
  static int _logoIdCounter = 0;
  static int nextTextId() => DateTime.now().microsecondsSinceEpoch + _textIdCounter++;
  static int _textIdCounter = 0;
  static String generateId() => '${DateTime.now().millisecondsSinceEpoch}_${_generateCounter++}';
  static int _generateCounter = 0;
  static int imageSig(Uint8List bytes) => bytes.length ^ bytes.hashCode;
}

/// Result of a save operation.
class ProcessResult {
  ProcessResult({required this.saved, required this.failed, required this.album});
  final int saved;
  final int failed;
  final String album;
}

/// Manages multiple projects and persists them.
class ProjectManager {
  ProjectManager._();
  static final ProjectManager _instance = ProjectManager._();
  factory ProjectManager() => _instance;

  final List<Project> _projects = [];
  int _activeIndex = 0;
  String? _exportDir;
  String? _saveDir;
  bool _initialized = false;

  List<Project> get projects => List.unmodifiable(_projects);
  int get activeIndex => _activeIndex;
  Project get activeProject => _projects[_activeIndex];
  String? get exportDir => _exportDir;
  String? get saveDir => _saveDir;

  /// Initialize and load projects from SharedPreferences.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _load();
    if (_projects.isEmpty) {
      _projects.add(Project(id: Project.generateId(), name: 'Projeto 1'));
      _activeIndex = 0;
      await save();
    }
  }

  /// Add a new project (copy of active project's settings).
  Future<Project> addProject({String? name}) async {
    final newProject = activeProject.copySettingsOnly(newName: name);
    _projects.add(newProject);
    _activeIndex = _projects.length - 1;
    await save();
    return newProject;
  }

  /// Remove a project. If it's the last one, create a new empty one.
  Future<void> removeProject(int index) async {
    if (_projects.length <= 1) return; // Keep at least one project
    _projects.removeAt(index);
    if (_activeIndex >= _projects.length) {
      _activeIndex = _projects.length - 1;
    }
    await save();
  }

  /// Set the active project by index.
  Future<void> setActive(int index) async {
    if (index >= 0 && index < _projects.length) {
      _activeIndex = index;
      await save();
    }
  }

  /// Update export directory (global).
  Future<void> setExportDir(String dir) async {
    _exportDir = dir;
    await save();
  }

  /// Update save directory (global).
  Future<void> setSaveDir(String dir) async {
    _saveDir = dir;
    await save();
  }

  /// Notify that active project changed (triggers UI update).
  void notifyActiveProjectChanged() {
    // This will be called by the UI after setActive
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final projectsJson = prefs.getStringList('projects') ?? [];
    final loaded = <Project>[];
    for (final jsonStr in projectsJson) {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        final project = await Project.fromJson(json);
        loaded.add(project);
      } catch (_) {
        // Skip corrupted project
      }
    }
    if (loaded.isNotEmpty) {
      _projects.addAll(loaded);
      _activeIndex = (prefs.getInt('activeProjectIndex') ?? 0).clamp(0, _projects.length - 1);
    }
    _exportDir = prefs.getString('exportDir');
    _saveDir = prefs.getString('saveDir');
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final projectsJson = _projects.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList('projects', projectsJson);
    await prefs.setInt('activeProjectIndex', _activeIndex);
    if (_exportDir != null) await prefs.setString('exportDir', _exportDir!);
    if (_saveDir != null) await prefs.setString('saveDir', _saveDir!);
  }
}
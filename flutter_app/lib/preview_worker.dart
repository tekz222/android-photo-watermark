import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'watermark_engine.dart';

/// A long-lived isolate that renders previews. Unlike `compute`, it keeps the
/// decoded photo/logo/text images between renders (see [DecodedCache]), so a
/// slider change only composites instead of decoding everything again.
///
/// Requests are sent one at a time; the ones still waiting can be dropped with
/// [cancelPending] when they are no longer wanted.
class PreviewWorker {
  Isolate? _isolate;
  SendPort? _send;
  final ReceivePort _receive = ReceivePort();
  final List<_Job> _queue = [];
  _Job? _inFlight;
  int _nextId = 0;
  bool _disposed = false;
  Object? _spawnError;

  Future<void> start() async {
    _receive.listen((msg) {
      if (msg is SendPort) {
        _send = msg;
        _pump();
      } else if (msg is List && msg.length == 2) {
        final job = _inFlight;
        if (job != null && job.id == msg[0]) {
          _inFlight = null;
          if (!job.done.isCompleted) job.done.complete(msg[1] as Uint8List?);
        }
        _pump();
      }
    });
    try {
      _isolate = await Isolate.spawn(_workerMain, _receive.sendPort);
    } catch (e) {
      _spawnError = e;
      cancelPending();
    }
  }

  /// Renders [r]; null if the render failed or was cancelled.
  Future<Uint8List?> render(WatermarkRequest r) {
    if (_disposed || _spawnError != null) return Future.value(null);
    final job = _Job(_nextId++, r);
    _queue.add(job);
    _pump();
    return job.done.future;
  }

  /// Drops every request that hasn't been sent yet (they complete with null).
  /// The one already rendering still finishes.
  void cancelPending() {
    for (final j in _queue) {
      if (!j.done.isCompleted) j.done.complete(null);
    }
    _queue.clear();
  }

  void _pump() {
    if (_send == null) return;
    if (_pendingPuts.isNotEmpty) {
      for (final m in _pendingPuts) {
        _send!.send(m);
      }
      _pendingPuts.clear();
    }
    if (_inFlight != null || _queue.isEmpty) return;
    final job = _queue.removeAt(0);
    _inFlight = job;
    _send!.send([job.id, job.request]);
  }

  /// Drops every cached decoded image (e.g. on "Novo projeto").
  void clearCache() => _send?.send('clear');

  final List<List<Object>> _pendingPuts = [];

  /// Stores raw RGBA pixels in the worker under [key] once, so renders can
  /// reference them with an empty payload instead of copying them every time.
  /// [group] evicts older pins of the same source (e.g. 't:3:').
  void putRaw(String key, int w, int h, Uint8List bytes, {String? group}) {
    final msg = <Object>['put', key, w, h, bytes, group ?? ''];
    if (_send == null) {
      _pendingPuts.add(msg);
    } else {
      _send!.send(msg);
    }
  }

  void dispose() {
    _disposed = true;
    cancelPending();
    final job = _inFlight;
    if (job != null && !job.done.isCompleted) job.done.complete(null);
    _inFlight = null;
    _isolate?.kill(priority: Isolate.immediate);
    _receive.close();
  }
}

class _Job {
  _Job(this.id, this.request);
  final int id;
  final WatermarkRequest request;
  final Completer<Uint8List?> done = Completer<Uint8List?>();
}

void _workerMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final cache = DecodedCache(capacity: 24);
  inbox.listen((msg) {
    if (msg == 'clear') {
      cache.clear();
    } else if (msg is List && msg.length == 6 && msg[0] == 'put') {
      try {
        final group = msg[5] as String;
        cache.pin(
          msg[1] as String,
          imageFromRaw(msg[2] as int, msg[3] as int, msg[4] as Uint8List),
          group: group.isEmpty ? null : group,
        );
      } catch (_) {}
    } else if (msg is List && msg.length == 2) {
      final id = msg[0] as int;
      Uint8List? result;
      try {
        result = renderWatermark(msg[1] as WatermarkRequest, cache: cache);
      } catch (_) {
        result = null;
      }
      out.send([id, result]);
    }
  });
}

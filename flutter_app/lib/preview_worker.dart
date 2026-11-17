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
  final Map<int, _Job> _inFlight = {};
  static const int _maxConcurrent = 4; // Process up to 4 renders in parallel
  int _nextId = 0;
  bool _disposed = false;
  Object? _spawnError;
  Completer<SendPort> _sendPortReady = Completer<SendPort>();

  Future<void> start() async {
    _receive.listen((msg) {
      if (msg is SendPort) {
        _send = msg;
        if (!_sendPortReady.isCompleted) {
          _sendPortReady.complete(msg);
        }
        _pump();
      } else if (msg is List && msg.length == 2) {
        final id = msg[0] as int;
        final job = _inFlight.remove(id);
        if (job != null && !job.done.isCompleted) {
          job.done.complete(msg[1] as Uint8List?);
        }
        _pump();
      }
    });
    try {
      _isolate = await Isolate.spawn(_workerMain, _receive.sendPort);
    } catch (e) {
      _spawnError = e;
      if (!_sendPortReady.isCompleted) {
        _sendPortReady.completeError(e);
      }
      cancelPending();
    }
  }

  /// Waits for the worker isolate to be ready (SendPort received).
  Future<void> ready() => _sendPortReady.future;

  /// Whether the worker is ready (SendPort received).
  bool get isReady => _sendPortReady.isCompleted && _send != null;

  /// Restarts the worker if it failed or was disposed.
  Future<void> restart() async {
    dispose();
    _sendPortReady = Completer<SendPort>();
    _disposed = false;
    _spawnError = null;
    await start();
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
  /// The ones already rendering still finish.
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
    // Send up to _maxConcurrent jobs
    while (_inFlight.length < _maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _inFlight[job.id] = job;
      _send!.send([job.id, job.request]);
    }
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
    for (final job in _inFlight.values) {
      if (!job.done.isCompleted) job.done.complete(null);
    }
    _inFlight.clear();
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

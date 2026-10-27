import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final Logger _log = Logger('SignalR');

/// Server-to-client method call received over the hub connection.
class SignalRInvocation {
  final String target;
  final List<dynamic> arguments;

  const SignalRInvocation(this.target, this.arguments);
}

/// Splits the SignalR JSON protocol byte stream into individual messages.
///
/// Messages are JSON documents terminated by the ASCII record separator
/// (0x1E). A single WebSocket frame may contain several messages or only part
/// of one, so incomplete tails are kept until the next chunk arrives.
class SignalRFrameDecoder {
  static const String recordSeparator = '\x1e';

  String _pending = '';

  List<String> add(String chunk) {
    _pending += chunk;
    final parts = _pending.split(recordSeparator);
    _pending = parts.removeLast();
    return parts.where((part) => part.isNotEmpty).toList();
  }

  void reset() => _pending = '';

  static String encode(Map<String, dynamic> message) =>
      '${jsonEncode(message)}$recordSeparator';
}

/// Minimal client for the ASP.NET Core SignalR JSON hub protocol over
/// WebSockets, enough to receive server pushes.
///
/// The connection is kept alive with pings, and re-established with an
/// exponential backoff whenever it drops, until [stop] is called.
class SignalRClient {
  final Uri hubUrl;
  final Map<String, String> headers;
  final Duration keepAliveInterval;
  final Duration serverTimeout;
  final http.Client _http;

  final StreamController<SignalRInvocation> _invocations =
      StreamController<SignalRInvocation>.broadcast();
  bool _running = false;
  int _generation = 0;
  WebSocket? _socket;
  Completer<void>? _backoffWake;

  SignalRClient({
    required this.hubUrl,
    this.headers = const {},
    this.keepAliveInterval = const Duration(seconds: 15),
    this.serverTimeout = const Duration(seconds: 40),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Stream<SignalRInvocation> get invocations => _invocations.stream;

  /// Begins connecting. Safe to call repeatedly.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_run(++_generation));
  }

  /// Closes the connection and stops reconnecting.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _generation++;
    final wake = _backoffWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    _http.close();
    await _invocations.close();
  }

  bool _isCurrent(int generation) => _running && generation == _generation;

  static Duration backoffFor(int failures) {
    const steps = [1, 2, 5, 10, 30];
    return Duration(seconds: steps[(failures - 1).clamp(0, steps.length - 1)]);
  }

  Future<void> _run(int generation) async {
    var failures = 0;
    while (_isCurrent(generation)) {
      final startedAt = DateTime.now();
      try {
        await _session(generation);
      } catch (error) {
        _log.fine('Hub session ended: $error');
      }
      if (!_isCurrent(generation)) break;
      // A connection that lasted a while counts as a fresh start rather than
      // another failure in a row.
      final wasStable =
          DateTime.now().difference(startedAt) > const Duration(seconds: 30);
      failures = wasStable ? 1 : failures + 1;
      await _sleep(backoffFor(failures), generation);
    }
  }

  Future<void> _sleep(Duration duration, int generation) async {
    final wake = Completer<void>();
    _backoffWake = wake;
    final timer = Timer(duration, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    if (identical(_backoffWake, wake)) _backoffWake = null;
  }

  Future<String> _negotiate() async {
    final negotiateUri = hubUrl.replace(
      path: '${hubUrl.path}/negotiate',
      queryParameters: {'negotiateVersion': '1'},
    );
    final response = await _http
        .post(negotiateUri, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException('Negotiate failed with ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['url'] != null) {
      throw const HttpException('Redirecting hubs are not supported');
    }
    final token = (body['connectionToken'] ?? body['connectionId']) as String?;
    if (token == null || token.isEmpty) {
      throw const HttpException('Negotiate response had no connection id');
    }
    return token;
  }

  Future<void> _session(int generation) async {
    final token = await _negotiate();
    if (!_isCurrent(generation)) return;

    final socketUrl = hubUrl.replace(
      scheme: hubUrl.scheme == 'http' ? 'ws' : 'wss',
      queryParameters: {'id': token},
    );
    final socket = await WebSocket.connect(
      socketUrl.toString(),
      headers: headers,
    ).timeout(const Duration(seconds: 15));
    if (!_isCurrent(generation)) {
      await socket.close();
      return;
    }
    _socket = socket;

    final closed = Completer<void>();
    final decoder = SignalRFrameDecoder();
    var handshakeComplete = false;
    var lastReceived = DateTime.now();

    void finish([Object? error]) {
      if (closed.isCompleted) return;
      if (error != null) {
        closed.completeError(error);
      } else {
        closed.complete();
      }
    }

    final keepAlive = Timer.periodic(keepAliveInterval, (_) {
      if (DateTime.now().difference(lastReceived) > serverTimeout) {
        finish(const HttpException('Server stopped responding'));
        return;
      }
      try {
        socket.add(SignalRFrameDecoder.encode({'type': 6}));
      } catch (_) {
        finish();
      }
    });

    socket.listen(
      (data) {
        lastReceived = DateTime.now();
        if (data is! String) return;
        for (final frame in decoder.add(data)) {
          Map<String, dynamic> message;
          try {
            message = jsonDecode(frame) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          if (!handshakeComplete) {
            final error = message['error'];
            if (error != null) {
              finish(HttpException('Handshake rejected: $error'));
              return;
            }
            handshakeComplete = true;
            continue;
          }
          switch (message['type']) {
            case 1:
              final target = message['target'] as String?;
              if (target != null && !_invocations.isClosed) {
                _invocations.add(
                  SignalRInvocation(
                    target,
                    (message['arguments'] as List<dynamic>?) ?? const [],
                  ),
                );
              }
            case 7:
              finish();
              return;
          }
        }
      },
      onError: (Object error) => finish(error),
      onDone: finish,
      cancelOnError: true,
    );

    socket.add(
      SignalRFrameDecoder.encode({'protocol': 'json', 'version': 1}),
    );

    try {
      await closed.future;
    } finally {
      keepAlive.cancel();
      if (identical(_socket, socket)) _socket = null;
      try {
        await socket.close();
      } catch (_) {}
    }
  }
}

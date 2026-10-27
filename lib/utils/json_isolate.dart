import 'dart:convert';
import 'dart:isolate';

/// Bodies at or above this size are decoded off the UI isolate.
const int _isolateDecodeThreshold = 32 * 1024;

/// Decodes [source] as JSON. Large payloads are parsed in a background
/// isolate so API responses never stall the UI thread; small ones are decoded
/// inline because spawning an isolate costs more than it saves.
Future<dynamic> decodeJsonAsync(String source) {
  if (source.length < _isolateDecodeThreshold) {
    return Future.value(jsonDecode(source));
  }
  return Isolate.run(() => jsonDecode(source));
}

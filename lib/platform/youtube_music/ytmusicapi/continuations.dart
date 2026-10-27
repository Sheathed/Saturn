import 'navigation.dart';
import 'type_alias.dart';

const _continuationTokenPath = [
  'continuationItemRenderer',
  'continuationEndpoint',
  'continuationCommand',
  'token',
];
const _continuationItemsPath = [
  'onResponseReceivedActions',
  0,
  'appendContinuationItemsAction',
  'continuationItems',
];

String? getContinuationToken(List<dynamic> results) {
  if (results.isEmpty) {
    return null;
  }
  final last = results.last;
  final token = nav(last, _continuationTokenPath, absent: true);
  if (token is String && token.isNotEmpty) {
    return token;
  }
  final commands = nav(last, [
    'continuationItemRenderer',
    'continuationEndpoint',
    'commandExecutorCommand',
    'commands',
  ], absent: true);
  if (commands is List) {
    for (final value in commands) {
      final command = asJsonDict(value);
      if (nav(command, ['continuationCommand', 'request'], absent: true) ==
          'CONTINUATION_REQUEST_TYPE_BROWSE') {
        return nav(command, ['continuationCommand', 'token'], absent: true)
            as String?;
      }
    }
  }
  return null;
}

JsonList getContinuationItems(JsonDict response) {
  final items = asJsonList(nav(response, _continuationItemsPath, absent: true));
  if (items.isNotEmpty) return items;
  final shelfContinuation = asJsonList(
    nav(response, [
      'continuationContents',
      'musicPlaylistShelfContinuation',
      'contents',
    ], absent: true),
  );
  if (shelfContinuation.isNotEmpty) return shelfContinuation;
  final musicShelfContinuation = asJsonList(
    nav(response, [
      'continuationContents',
      'musicShelfContinuation',
      'contents',
    ], absent: true),
  );
  if (musicShelfContinuation.isNotEmpty) return musicShelfContinuation;
  return const [];
}

/// Builds the paired continuation parameters used by the Innertube request.
String continuationParameters(String token) =>
    '&ctoken=$token&continuation=$token';

String getContinuationParameters(JsonDict results, {String ctokenPath = ''}) {
  final token = nav(results, [
    'continuations',
    0,
    'next${ctokenPath}ContinuationData',
    'continuation',
  ]);
  if (token is! String || token.isEmpty) {
    throw StateError('Continuation data did not include a token.');
  }
  return continuationParameters(token);
}

Future<List<T>> getContinuations<T>({
  required JsonDict initial,
  required String continuationType,
  String ctokenPath = '',
  int? limit,
  required Future<JsonDict> Function(String params) request,
  required List<T> Function(JsonList rows) parse,
}) async {
  var results = initial;
  final items = <T>[];
  while (results.containsKey('continuations') &&
      (limit == null || items.length < limit)) {
    final params = getContinuationParameters(results, ctokenPath: ctokenPath);
    final response = await request(params);
    final next = asJsonDict(
      nav(response, ['continuationContents', continuationType], absent: true),
    );
    if (next == null) {
      break;
    }
    results = next;
    final rows = asJsonList(next['contents'] ?? next['items']);
    final parsed = parse(rows);
    if (parsed.isEmpty) {
      break;
    }
    items.addAll(parsed);
  }
  return items;
}

/// Fetches all renderer items until the limit or end of the continuation chain.
Future<JsonList> getContinuations2025({
  required JsonDict initial,
  int? limit,
  required Future<JsonDict> Function(JsonDict body) request,
  required JsonList Function(JsonList rows) parse,
}) async {
  final contents = asJsonList(initial['contents']);
  var token = getContinuationToken(contents);
  final collected = <JsonDict>[];
  while (token != null && (limit == null || collected.length < limit)) {
    final response = await request({'continuation': token});
    final rows = getContinuationItems(response);
    if (rows.isEmpty) {
      break;
    }
    final parsed = parse(rows);
    if (parsed.isEmpty) {
      break;
    }
    collected.addAll(parsed);
    token = getContinuationToken(rows);
  }
  return collected;
}

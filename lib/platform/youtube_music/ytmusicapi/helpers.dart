import 'dart:math' as math;

import 'navigation.dart';
import 'type_alias.dart';

String initializeClientVersion(DateTime now) =>
    '1.${now.toUtc().year.toString().padLeft(4, '0')}${now.toUtc().month.toString().padLeft(2, '0')}${now.toUtc().day.toString().padLeft(2, '0')}.01.00';

JsonDict initializeContext({
  required String clientVersion,
  String clientName = 'WEB_REMIX',
}) => {
  'context': {
    'client': {'clientName': clientName, 'clientVersion': clientVersion},
    'user': <String, dynamic>{},
  },
};

int toInt(String string) {
  final digits = string.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) {
    throw FormatException('Not an integer: $string');
  }
  return int.parse(digits);
}

int sumTotalDuration(JsonDict item) {
  final tracks = item['tracks'];
  if (tracks is! List) {
    return 0;
  }
  return tracks.fold<int>(0, (total, value) {
    final seconds = asJsonDict(value)?['duration_seconds'];
    return total + (seconds is int ? seconds : 0);
  });
}

Map<String, dynamic> parseDescriptionRuns(dynamic values) {
  if (values is! List) {
    return {'description': '', 'descriptionRuns': <JsonDict>[]};
  }
  final description = StringBuffer();
  final runs = <JsonDict>[];
  for (final value in values) {
    final run = asJsonDict(value);
    if (run == null) {
      continue;
    }
    final text = run['text']?.toString() ?? '';
    description.write(text);
    final url = nav(run, [
      'navigationEndpoint',
      'urlEndpoint',
      'url',
    ], absent: true);
    runs.add({'text': text, 'url': ?url});
  }
  return {'description': description.toString(), 'descriptionRuns': runs};
}

int clampItemLimit(int? limit, int available) =>
    limit == null ? available : math.max(0, math.min(limit, available));

String? prepareOrderParams(String? order) {
  if (order == null) {
    return null;
  }
  return switch (order) {
    'a_to_z' => 'ggMGKgQIARAA',
    'z_to_a' => 'ggMGKgQIARAB',
    'recently_added' => 'ggMGKgQIABAB',
    _ => throw ArgumentError.value(
      order,
      'order',
      'Use a_to_z, z_to_a, or recently_added.',
    ),
  };
}

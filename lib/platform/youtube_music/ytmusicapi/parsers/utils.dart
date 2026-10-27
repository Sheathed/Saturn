import '../navigation.dart';
import '../type_alias.dart';
import 'constants.dart';

String? getItemText(
  JsonDict item,
  int index, {
  int runIndex = 0,
  bool noneIfAbsent = false,
}) {
  final column = getFlexColumnItem(item, index);
  final runs = nav(column, ['text', 'runs'], absent: true);
  if (runs is! List ||
      (noneIfAbsent && runs.length <= runIndex) ||
      runs.length <= runIndex) {
    return null;
  }
  return asJsonDict(runs[runIndex])?['text'] as String?;
}

JsonDict? getFlexColumnItem(JsonDict item, int index) {
  final columns = item['flexColumns'];
  if (columns is! List || index < 0 || index >= columns.length) {
    return null;
  }
  final renderer = asJsonDict(
    columns[index],
  )?['musicResponsiveListItemFlexColumnRenderer'];
  final column = asJsonDict(renderer);
  final runs = nav(column, ['text', 'runs'], absent: true);
  return runs is List ? column : null;
}

JsonDict? getFixedColumnItem(JsonDict item, int index) {
  final columns = item['fixedColumns'];
  if (columns is! List || index < 0 || index >= columns.length) {
    return null;
  }
  final column = asJsonDict(
    asJsonDict(columns[index])?['musicResponsiveListItemFixedColumnRenderer'],
  );
  return nav(column, ['text', 'runs'], absent: true) is List ? column : null;
}

int getDotSeparatorIndex(List<dynamic> runs) {
  for (var i = 0; i < runs.length; i++) {
    final run = asJsonDict(runs[i]);
    if (run?['text'] == dotSeparatorRun['text']) {
      return i;
    }
  }
  return runs.length;
}

int? parseDuration(String? duration) {
  if (duration == null || duration.trim().isEmpty) {
    return null;
  }
  final parts = duration.trim().split(':');
  if (parts.any((part) => int.tryParse(part) == null)) {
    return null;
  }
  var seconds = 0;
  for (final part in parts) {
    seconds = seconds * 60 + int.parse(part);
  }
  return seconds;
}

String parseRuns(dynamic value) {
  if (value is String) {
    return value;
  }
  final runs = value is Map ? value['runs'] : null;
  if (runs is! List) {
    return '';
  }
  return runs.map((run) => asJsonDict(run)?['text'] ?? '').join();
}

JsonDict parseIdName(JsonDict? subRun) => {
  'id': nav(subRun, navigationBrowseId, absent: true),
  'name': nav(subRun, ['text'], absent: true),
};

import '../navigation.dart';
import '../type_alias.dart';
import '../helpers.dart' show prepareOrderParams;

const libraryOrderTypes = {'a_to_z', 'z_to_a', 'recently_added'};

String prepareLikeEndpoint(String rating) => switch (rating) {
  'LIKE' => 'like/like',
  'DISLIKE' => 'like/dislike',
  'INDIFFERENT' => 'like/removelike',
  _ => throw ArgumentError.value(rating, 'rating'),
};

void validateOrderParameter(String? order) {
  if (order != null && !libraryOrderTypes.contains(order)) {
    throw ArgumentError.value(order, 'order', libraryOrderTypes.join(', '));
  }
}

String prepareOrderParamsForLibrary(String order) {
  validateOrderParameter(order);
  return prepareOrderParams(order)!;
}

String htmlToText(String html) => html.replaceAll(RegExp(r'<[^>]+>'), '');

void validateWriteResponse(JsonDict response) {
  final panel = nav(response, [
    'actions',
    0,
    'showEngagementPanelEndpoint',
  ], absent: true);
  if (panel != null) {
    final tag = nav(panel, ['identifier', 'tag'], absent: true);
    throw StateError(
      'YouTube Music gated the write request with engagement panel $tag.',
    );
  }
}

int getDateStamp([DateTime? now]) {
  final utc = (now ?? DateTime.now()).toUtc();
  return utc.difference(DateTime.utc(1970)).inDays;
}

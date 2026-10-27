typedef JsonDict = Map<String, dynamic>;
typedef JsonList = List<JsonDict>;

JsonDict? asJsonDict(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

JsonList asJsonList(dynamic value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : <JsonDict>[];

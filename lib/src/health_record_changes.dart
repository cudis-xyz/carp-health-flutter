part of '../health.dart';

/// A complete native record. Its points retain the original native UUID.
///
/// Parent dates describe the native record, not the first/last series point.
/// [nativeType] is the representative Dart type used to create the query/token.
class HealthDataRecord {
  final String id;
  final HealthDataType nativeType;
  final DateTime dateFrom;
  final DateTime dateTo;
  final List<HealthDataPoint> points;

  HealthDataRecord._(this.id, this.nativeType, this.dateFrom, this.dateTo, List<HealthDataPoint> points)
    : points = List.unmodifiable(points);

  factory HealthDataRecord.fromMethodChannel(Object? payload, {required HealthDataType type}) {
    final map = _recordMap(payload);
    _recordType(map, type);
    final id = _recordString(map['id'], 'id');
    final from = _recordDate(map['date_from']);
    final to = _recordDate(map['date_to']);
    if (to.isBefore(from)) throw const FormatException('Invalid native record interval');
    final pointTypes = _recordPointTypes(type);
    final points = _recordList(map['points']).map((payload) {
      final point = _recordMap(payload);
      final pointType = _healthDataTypeFromName(_recordString(point['dataTypeKey'], 'dataTypeKey'));
      if (pointType == null || !pointTypes.contains(pointType)) {
        throw const FormatException('Point type does not match native record');
      }
      if (_recordString(point['uuid'], 'uuid') != id) {
        throw const FormatException('Point UUID does not match native record');
      }
      final unit = _recordString(point['dataUnitKey'], 'dataUnitKey');
      if (unit != dataTypeToUnit[pointType]?.name) throw const FormatException('Invalid point unit');
      final value = point['value'];
      if (value is! num || !value.isFinite) throw const FormatException('Invalid point value');
      final pointFrom = _recordDate(point['date_from']);
      final pointTo = _recordDate(point['date_to']);
      if (pointTo.isBefore(pointFrom)) throw const FormatException('Invalid point interval');
      final recording = point['recording_method'];
      if (recording != null && (recording is! int || recording < 0 || recording > 3)) {
        throw const FormatException('Invalid recording method');
      }
      try {
        return HealthDataPoint.fromHealthDataPoint(pointType, point, unit);
      } on TypeError {
        throw const FormatException('Invalid point fields');
      } on ArgumentError {
        throw const FormatException('Invalid point fields');
      }
    }).toList();
    return HealthDataRecord._(id, type, from, to, points);
  }
}

/// An upsert contains a complete native record; a deletion contains only its ID.
class HealthRecordChange {
  final HealthChangeType type;
  final String recordId;
  final HealthDataType nativeType;
  final HealthDataRecord? record;

  HealthRecordChange._(this.type, this.recordId, this.nativeType, this.record);

  factory HealthRecordChange.fromMethodChannel(Object? payload, {required HealthDataType type}) {
    final map = _recordMap(payload);
    _recordType(map, type);
    final id = _recordString(map['recordId'], 'recordId');
    switch (map['type']) {
      case 'delete':
        if (map['record'] != null) throw const FormatException('Deletion contains a record');
        return HealthRecordChange._(HealthChangeType.delete, id, type, null);
      case 'upsert':
        final record = HealthDataRecord.fromMethodChannel(map['record'], type: type);
        if (record.id != id) throw const FormatException('Change ID does not match record');
        return HealthRecordChange._(HealthChangeType.upsert, id, type, record);
      default:
        throw const FormatException('Unknown record change operation');
    }
  }
}

/// One Health Connect snapshot page. A null [nextPageToken] means exhausted.
class HealthRecordSnapshotResponse {
  final HealthDataType nativeType;
  final List<HealthDataRecord> records;
  final String? nextPageToken;

  HealthRecordSnapshotResponse._(this.nativeType, List<HealthDataRecord> records, this.nextPageToken)
    : records = List.unmodifiable(records);

  factory HealthRecordSnapshotResponse.fromMethodChannel(Object? payload, {required HealthDataType type}) {
    final map = _recordMap(payload);
    _recordType(map, type);
    if (!map.containsKey('nextPageToken')) throw const FormatException('Missing nextPageToken');
    final token = map['nextPageToken'];
    if (token != null && token is! String) throw const FormatException('Invalid nextPageToken');
    return HealthRecordSnapshotResponse._(
      type,
      _recordList(map['records']).map((record) => HealthDataRecord.fromMethodChannel(record, type: type)).toList(),
      token == '' ? null : token as String?,
    );
  }
}

/// One Health Connect changes page. Expiration requires caller-managed recovery.
class HealthRecordChangesResponse {
  final HealthDataType nativeType;
  final List<HealthRecordChange> changes;

  /// May be empty on an expired response. Never commit an expired position.
  final String nextChangesToken;
  final bool hasMore;
  final bool changesTokenExpired;

  HealthRecordChangesResponse._(
    this.nativeType,
    List<HealthRecordChange> changes,
    this.nextChangesToken,
    this.hasMore,
    this.changesTokenExpired,
  ) : changes = List.unmodifiable(changes);

  factory HealthRecordChangesResponse.fromMethodChannel(Object? payload, {required HealthDataType type}) {
    final map = _recordMap(payload);
    _recordType(map, type);
    final expired = _recordBool(map['changesTokenExpired']);
    final token = map['nextChangesToken'];
    // connect-client 1.2.0-alpha02 returns an empty token on Android 14 expiry.
    if (token is! String || (!expired && token.isEmpty)) {
      throw const FormatException('Missing or invalid nextChangesToken');
    }
    return HealthRecordChangesResponse._(
      type,
      _recordList(map['changes']).map((change) => HealthRecordChange.fromMethodChannel(change, type: type)).toList(),
      token,
      _recordBool(map['hasMore']),
      expired,
    );
  }
}

/// One HealthKit anchored page. Keep the same type and start date for its anchor.
class HealthAnchoredRecordsResponse {
  final HealthDataType nativeType;
  final List<HealthRecordChange> changes;
  final String nextAnchor;
  final bool hasMore;

  HealthAnchoredRecordsResponse._(this.nativeType, List<HealthRecordChange> changes, this.nextAnchor, this.hasMore)
    : changes = List.unmodifiable(changes);

  factory HealthAnchoredRecordsResponse.fromMethodChannel(Object? payload, {required HealthDataType type}) {
    final map = _recordMap(payload);
    _recordType(map, type);
    return HealthAnchoredRecordsResponse._(
      type,
      _recordList(map['changes']).map((change) => HealthRecordChange.fromMethodChannel(change, type: type)).toList(),
      _recordString(map['nextAnchor'], 'nextAnchor'),
      _recordBool(map['hasMore']),
    );
  }
}

const _recordScalarTypes = {
  HealthDataType.STEPS,
  HealthDataType.HEART_RATE,
  HealthDataType.RESTING_HEART_RATE,
  HealthDataType.BLOOD_OXYGEN,
};
const _recordSleepTypes = {
  HealthDataType.SLEEP_ASLEEP,
  HealthDataType.SLEEP_AWAKE,
  HealthDataType.SLEEP_IN_BED,
  HealthDataType.SLEEP_AWAKE_IN_BED,
  HealthDataType.SLEEP_OUT_OF_BED,
  HealthDataType.SLEEP_DEEP,
  HealthDataType.SLEEP_LIGHT,
  HealthDataType.SLEEP_REM,
  HealthDataType.SLEEP_UNKNOWN,
  HealthDataType.SLEEP_SESSION,
};

Set<HealthDataType> _recordPointTypes(HealthDataType type) => switch (type) {
  HealthDataType.SLEEP_SESSION => _recordSleepTypes.intersection(dataTypeKeysAndroid.toSet()),
  HealthDataType.SLEEP_ASLEEP => _recordSleepTypes.intersection(dataTypeKeysIOS.toSet()),
  _ => {type},
};

Map<Object?, Object?> _recordMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected a native record map');
  return value;
}

List<Object?> _recordList(Object? value) {
  if (value is! List) throw const FormatException('Expected a native record list');
  return value;
}

String _recordString(Object? value, String field) {
  if (value is! String || value.isEmpty) throw FormatException('Missing or invalid $field');
  return value;
}

bool _recordBool(Object? value) {
  if (value is! bool) throw const FormatException('Expected a native pagination flag');
  return value;
}

DateTime _recordDate(Object? value) {
  if (value is! int || value < -8640000000000000 || value > 8640000000000000) {
    throw const FormatException('Invalid native timestamp');
  }
  return DateTime.fromMillisecondsSinceEpoch(value);
}

void _recordType(Map<Object?, Object?> map, HealthDataType type) {
  if (map['nativeType'] != type.name) throw const FormatException('Native type does not match request');
}

// Count points, since a single series record can contain a large payload.
bool _recordPayloadIsLarge(Object? payload) {
  final map = _recordMap(payload);
  final entries = _recordList(map['records'] ?? map['changes']);
  var count = entries.length;
  for (final entry in entries) {
    if (count > 100) return true;
    final map = _recordMap(entry);
    final record = map['record'] ?? map;
    if (record is Map && record['points'] is List) count += (record['points'] as List).length;
  }
  return count > 100;
}

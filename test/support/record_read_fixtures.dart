import 'package:health/health.dart';

Map<String, Object?> recordPoint({
  HealthDataType type = HealthDataType.HEART_RATE,
  String id = 'native-id',
  num value = 72,
  int start = 1800000000000,
  int? end,
}) => {
  'uuid': id,
  'dataTypeKey': type.name,
  'dataUnitKey': dataTypeToUnit[type]!.name,
  'value': value,
  'date_from': start,
  'date_to': end ?? start,
  'source_id': '',
  'source_name': 'com.example.health',
  'recording_method': 2,
};

Map<String, Object?> nativeRecord({
  HealthDataType type = HealthDataType.HEART_RATE,
  List<Map<String, Object?>>? points,
}) => {
  'id': 'native-id',
  'nativeType': type.name,
  'date_from': 1800000000000,
  'date_to': 1800000905000,
  'points': points ?? [recordPoint(type: type)],
};

Map<String, Object?> recordSnapshot({
  HealthDataType type = HealthDataType.HEART_RATE,
  List<Map<String, Object?>>? records,
  String? token,
}) => {
  'nativeType': type.name,
  'records': records ?? [nativeRecord(type: type)],
  'nextPageToken': token,
};

Map<String, Object?> recordChanges({
  HealthDataType type = HealthDataType.HEART_RATE,
  List<Map<String, Object?>>? changes,
  bool hasMore = false,
  bool expired = false,
  String token = 'next-token',
}) => {
  'nativeType': type.name,
  'changes':
      changes ??
      [
        {'type': 'upsert', 'nativeType': type.name, 'recordId': 'native-id', 'record': nativeRecord(type: type)},
        {'type': 'delete', 'nativeType': type.name, 'recordId': 'deleted-id'},
      ],
  'nextChangesToken': token,
  'hasMore': hasMore,
  'changesTokenExpired': expired,
};

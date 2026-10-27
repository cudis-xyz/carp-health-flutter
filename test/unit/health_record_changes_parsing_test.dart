import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import '../support/record_read_fixtures.dart';

void main() {
  const hr = HealthDataType.HEART_RATE;
  test('HR retains parent dates, all points, shared UUID and input order', () {
    final record = HealthDataRecord.fromMethodChannel(
      nativeRecord(
        points: [
          recordPoint(value: 75, start: 1800000120000),
          recordPoint(value: 60),
          recordPoint(value: 90, start: 1800000300000),
        ],
      ),
      type: hr,
    );
    expect(record.id, 'native-id');
    expect(record.dateFrom.millisecondsSinceEpoch, 1800000000000);
    expect(record.dateTo.millisecondsSinceEpoch, 1800000905000);
    expect(record.points.map((point) => (point.value as NumericHealthValue).numericValue), [75, 60, 90]);
    expect(record.points.map((point) => point.uuid).toSet(), {'native-id'});
    expect(() => record.points.clear(), throwsUnsupportedError);
  });

  test('sleep session and stages retain old values, units and defaults', () {
    final stage = recordPoint(type: HealthDataType.SLEEP_DEEP, value: 4, end: 1800000905000)
      ..remove('recording_method');
    final record = HealthDataRecord.fromMethodChannel(
      nativeRecord(
        type: HealthDataType.SLEEP_SESSION,
        points: [
          recordPoint(type: HealthDataType.SLEEP_SESSION, value: 15),
          stage,
        ],
      ),
      type: HealthDataType.SLEEP_SESSION,
    );
    expect(record.points.map((point) => (point.value as NumericHealthValue).numericValue), [15, 905 / 60]);
    expect(record.points.last.recordingMethod, RecordingMethod.unknown);
    expect(record.points.last.unit, HealthDataUnit.MINUTE);
  });

  for (final entry in {
    HealthDataType.SLEEP_ASLEEP: HealthDataType.SLEEP_SESSION,
    HealthDataType.SLEEP_SESSION: HealthDataType.SLEEP_IN_BED,
  }.entries) {
    test('${entry.key.name} rejects a sleep point from the other platform', () {
      expect(
        () => HealthDataRecord.fromMethodChannel(
          nativeRecord(
            type: entry.key,
            points: [recordPoint(type: entry.value)],
          ),
          type: entry.key,
        ),
        throwsFormatException,
      );
    });
  }

  for (final type in [
    HealthDataType.STEPS,
    hr,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.HEART_RATE_VARIABILITY_SDNN,
    HealthDataType.BLOOD_OXYGEN,
    HealthDataType.BODY_TEMPERATURE,
    HealthDataType.SLEEP_ASLEEP,
  ]) {
    test('${type.name} matches the existing point factory exactly', () {
      final map = recordPoint(type: type, end: 1800000905000);
      final old = HealthDataPoint.fromHealthDataPoint(type, map, dataTypeToUnit[type]!.name);
      final current = HealthDataRecord.fromMethodChannel(
        nativeRecord(type: type, points: [map]),
        type: type,
      ).points.single;
      expect(current.toJson(), old.toJson());
    });
  }

  final invalidPoints = <String, Object?>{
    'missing uuid': {'uuid': null},
    'different UUID': {'uuid': 'other'},
    'unknown type': {'dataTypeKey': 'NEW_TYPE'},
    'different type': {'dataTypeKey': 'STEPS'},
    'unknown unit': {'dataUnitKey': 'bpm'},
    'wrong unit': {'dataUnitKey': 'COUNT'},
    'missing value': {'value': null},
    'wrong value': {'value': '72'},
    'infinite value': {'value': double.infinity},
    'nan value': {'value': double.nan},
    'fractional timestamp': {'date_from': 1.5},
    'out of range date': {'date_from': 8640000000000001},
    'minimum signed timestamp': {'date_from': -9223372036854775808},
    'reversed dates': {'date_to': 1},
    'missing source': {'source_name': null},
    'invalid source ID': {'source_id': 42},
    'wrong recording': {'recording_method': 5},
    'invalid device model': {'device_model': 42},
    'invalid metadata': {'metadata': 'not a map'},
  };
  for (final entry in invalidPoints.entries) {
    test('${entry.key} fails the whole record/page', () {
      final point = recordPoint()..addAll(Map<String, Object?>.from(entry.value as Map));
      expect(
        () => HealthRecordSnapshotResponse.fromMethodChannel(
          recordSnapshot(
            records: [
              nativeRecord(),
              nativeRecord(points: [point]),
            ],
          ),
          type: hr,
        ),
        throwsFormatException,
      );
    });
  }

  for (final token in <String?>[null, '']) {
    test('snapshot terminal token $token is accepted', () {
      final page = HealthRecordSnapshotResponse.fromMethodChannel(recordSnapshot(token: token), type: hr);
      expect(page.nextPageToken, isNull);
    });
  }
  test('missing snapshot cursor is not interpreted as exhaustion', () {
    expect(
      () => HealthRecordSnapshotResponse.fromMethodChannel(recordSnapshot()..remove('nextPageToken'), type: hr),
      throwsFormatException,
    );
  });
  test('ID-only delete and empty changes preserve pagination', () {
    final page = HealthRecordChangesResponse.fromMethodChannel(
      recordChanges(
        changes: [
          {'type': 'delete', 'recordId': 'deleted-id', 'nativeType': hr.name},
        ],
        hasMore: true,
      ),
      type: hr,
    );
    expect(page.changes.single.type, HealthChangeType.delete);
    expect(page.changes.single.record, isNull);
    expect(page.hasMore, isTrue);
    final empty = HealthRecordChangesResponse.fromMethodChannel(recordChanges(changes: []), type: hr);
    expect(empty.changes, isEmpty);
    expect(empty.nextChangesToken, 'next-token');
  });
  test('expired flag is explicit', () {
    expect(
      HealthRecordChangesResponse.fromMethodChannel(
        recordChanges(changes: [], expired: true, token: ''),
        type: hr,
      ).changesTokenExpired,
      isTrue,
    );
  });
  for (final change in [
    {'type': 'unknown', 'recordId': 'id', 'nativeType': hr.name},
    {'type': 'delete', 'recordId': '', 'nativeType': hr.name},
    {'type': 'delete', 'recordId': 'id', 'nativeType': 'STEPS'},
    {'type': 'upsert', 'recordId': 'id', 'nativeType': hr.name},
    {'type': 'upsert', 'recordId': 'other-id', 'nativeType': hr.name, 'record': nativeRecord()},
  ]) {
    test('malformed change $change is not ignored', () {
      expect(
        () => HealthRecordChangesResponse.fromMethodChannel(recordChanges(changes: [change]), type: hr),
        throwsFormatException,
      );
    });
  }
  for (final payload in [
    null,
    <Object?>[],
    'bad',
    <String, Object?>{},
    recordChanges()..remove('hasMore'),
    recordChanges()..['nextChangesToken'] = '',
    recordChanges()..['changes'] = [null],
  ]) {
    test('malformed response fails strictly: ${payload.runtimeType}', () {
      expect(() => HealthRecordChangesResponse.fromMethodChannel(payload, type: hr), throwsFormatException);
    });
  }
  test('anchored delete-only page uses its raw hasMore and secure anchor string', () {
    final page = HealthAnchoredRecordsResponse.fromMethodChannel({
      'nativeType': HealthDataType.SLEEP_ASLEEP.name,
      'changes': [
        {'type': 'delete', 'nativeType': HealthDataType.SLEEP_ASLEEP.name, 'recordId': 'deleted'},
      ],
      'nextAnchor': 'opaque-anchor',
      'hasMore': true,
    }, type: HealthDataType.SLEEP_ASLEEP);
    expect(page.changes.single.recordId, 'deleted');
    expect(page.hasMore, isTrue);
  });
}

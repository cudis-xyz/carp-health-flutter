import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import '../support/health_test_context.dart';
import '../support/record_read_fixtures.dart';
import '../support/stub_device_info.dart';

// Exercises the existing virtual platform getter; no production test switches.
class _PlatformHealth extends Health {
  _PlatformHealth(this.platform) : super(deviceInfo: StubDeviceInfoPlugin());
  final HealthPlatformType platform;
  @override
  HealthPlatformType get platformType => platform;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HealthTestContext ctx;
  late Health android;
  late Health apple;
  final start = DateTime.fromMillisecondsSinceEpoch(1800000000000);
  final end = start.add(const Duration(days: 1));
  const hr = HealthDataType.HEART_RATE;
  setUp(() async {
    ctx = HealthTestContext();
    await ctx.setUp();
    android = _PlatformHealth(HealthPlatformType.googleHealthConnect);
    apple = _PlatformHealth(HealthPlatformType.appleHealth);
  });
  tearDown(() => ctx.tearDown());

  test('single type token does not use legacy availability or normalize types', () async {
    ctx.channel.when('getHealthRecordChangesToken', 'opaque');
    expect(await android.getHealthRecordChangesToken(type: hr), 'opaque');
    expect(ctx.channel.calls.map((call) => call.method), ['getHealthRecordChangesToken']);
    expect(ctx.channel.lastCall.arguments, {'dataTypeKey': 'HEART_RATE'});
  });
  test('snapshot forwards fixed query bounds, unit, token and one page size', () async {
    ctx.channel.when('getHealthRecordSnapshot', recordSnapshot(token: 'page-2'));
    final page = await android.getHealthRecordSnapshot(
      type: hr,
      startTime: start,
      endTime: end,
      pageToken: 'page-1',
      pageSize: 12,
    );
    expect(page.nextPageToken, 'page-2');
    expect(ctx.channel.calls, hasLength(1));
    expect(ctx.channel.lastCall.arguments, {
      'dataTypeKey': 'HEART_RATE',
      'dataUnitKey': 'BEATS_PER_MINUTE',
      'startTime': start.millisecondsSinceEpoch,
      'endTime': end.millisecondsSinceEpoch,
      'pageToken': 'page-1',
      'pageSize': 12,
    });
  });
  test('changes forwards unmodified token and never filters self', () async {
    ctx.channel.when('getHealthRecordChanges', recordChanges());
    final page = await android.getHealthRecordChanges(type: hr, changesToken: 'token-1');
    expect(page.changes, hasLength(2));
    expect(ctx.channel.lastCall.arguments, {
      'dataTypeKey': 'HEART_RATE',
      'dataUnitKey': 'BEATS_PER_MINUTE',
      'changesToken': 'token-1',
    });
  });
  test('anchored request has fixed lower bound and no future-blocking end date', () async {
    ctx.channel.when('getAnchoredHealthRecords', {
      'nativeType': hr.name,
      'changes': <Object?>[],
      'nextAnchor': 'anchor-2',
      'hasMore': false,
    });
    expect(
      (await apple.getAnchoredHealthRecords(type: hr, startTime: start, anchor: 'anchor-1', limit: 17)).nextAnchor,
      'anchor-2',
    );
    expect(ctx.channel.lastCall.arguments, {
      'dataTypeKey': hr.name,
      'dataUnitKey': 'BEATS_PER_MINUTE',
      'startTime': start.millisecondsSinceEpoch,
      'anchor': 'anchor-1',
      'limit': 17,
    });
  });
  test('unsupported platform and derived types fail before channel access', () async {
    await expectLater(apple.getHealthRecordChangesToken(type: hr), throwsUnsupportedError);
    await expectLater(android.getAnchoredHealthRecords(type: hr, startTime: start), throwsUnsupportedError);
    await expectLater(
      android.getHealthRecordChangesToken(type: HealthDataType.BODY_MASS_INDEX),
      throwsUnsupportedError,
    );
    await expectLater(
      apple.getAnchoredHealthRecords(type: HealthDataType.SLEEP_DEEP, startTime: start),
      throwsUnsupportedError,
    );
    expect(ctx.channel.calls, isEmpty);
  });
  test('invalid arguments fail before reading', () async {
    for (final size in [0, -1, 5001]) {
      await expectLater(
        android.getHealthRecordSnapshot(type: hr, startTime: start, endTime: end, pageSize: size),
        throwsArgumentError,
      );
    }
    await expectLater(android.getHealthRecordSnapshot(type: hr, startTime: end, endTime: start), throwsArgumentError);
    await expectLater(
      android.getHealthRecordSnapshot(type: hr, startTime: start, endTime: end, pageToken: ''),
      throwsArgumentError,
    );
    await expectLater(android.getHealthRecordChanges(type: hr, changesToken: ''), throwsArgumentError);
    await expectLater(apple.getAnchoredHealthRecords(type: hr, startTime: start, anchor: ''), throwsArgumentError);
    await expectLater(apple.getAnchoredHealthRecords(type: hr, startTime: start, limit: 0), throwsArgumentError);
    expect(ctx.channel.calls, isEmpty);
  });
  for (final code in ['permission_denied', 'rate_limited', 'health_read_error', 'invalid_cursor', 'cancelled']) {
    test('$code propagates unmodified through all four entrypoints', () async {
      final details = {'domain': 'native', 'code': 42, 'nativeErrorCode': code == 'permission_denied' ? 5 : null};
      await ctx.channel.setUp(
        responder: (_) async => throw PlatformException(code: code, message: 'native failure', details: details),
      );
      for (final read in <Future<Object?> Function()>[
        () => android.getHealthRecordChangesToken(type: hr),
        () => android.getHealthRecordSnapshot(type: hr, startTime: start, endTime: end),
        () => android.getHealthRecordChanges(type: hr, changesToken: 'token'),
        () => apple.getAnchoredHealthRecords(type: hr, startTime: start),
      ]) {
        await expectLater(
          read(),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', code).having((e) => e.details, 'details', details),
          ),
        );
      }
    });
  }
  test('cursor stalls fail; unchanged terminal cursor is legal', () async {
    ctx.channel.when('getHealthRecordSnapshot', recordSnapshot(token: 'same'));
    await expectLater(
      android.getHealthRecordSnapshot(type: hr, startTime: start, endTime: end, pageToken: 'same'),
      throwsFormatException,
    );
    ctx.channel.when('getHealthRecordChanges', recordChanges(token: 'same', hasMore: true));
    await expectLater(android.getHealthRecordChanges(type: hr, changesToken: 'same'), throwsFormatException);
    ctx.channel.when('getHealthRecordChanges', recordChanges(token: 'same', changes: []));
    expect((await android.getHealthRecordChanges(type: hr, changesToken: 'same')).hasMore, isFalse);
  });
  test('anchored cursor stalls fail; unchanged terminal anchor is legal', () async {
    final payload = {'nativeType': hr.name, 'changes': <Object?>[], 'nextAnchor': 'same', 'hasMore': true};
    ctx.channel.when('getAnchoredHealthRecords', payload);
    await expectLater(
      apple.getAnchoredHealthRecords(type: hr, startTime: start, anchor: 'same'),
      throwsFormatException,
    );
    payload['hasMore'] = false;
    expect((await apple.getAnchoredHealthRecords(type: hr, startTime: start, anchor: 'same')).hasMore, isFalse);
  });
  test('expired changes are preserved before checking cursor progress', () async {
    ctx.channel.when('getHealthRecordChanges', recordChanges(changes: [], token: '', expired: true));
    final page = await android.getHealthRecordChanges(type: hr, changesToken: 'original');
    expect(page.changesTokenExpired, isTrue);
    expect(page.nextChangesToken, isEmpty);
  });
  for (final method in ['getHealthRecordSnapshot', 'getHealthRecordChanges', 'getAnchoredHealthRecords']) {
    Future<List<HealthDataPoint>> readPoints() async {
      switch (method) {
        case 'getHealthRecordSnapshot':
          final page = await android.getHealthRecordSnapshot(type: hr, startTime: start, endTime: end);
          return page.records.single.points;
        case 'getHealthRecordChanges':
          final page = await android.getHealthRecordChanges(type: hr, changesToken: 'original');
          return page.changes.single.record!.points;
        default:
          final page = await apple.getAnchoredHealthRecords(type: hr, startTime: start);
          return page.changes.single.record!.points;
      }
    }

    void respond(List<Map<String, Object?>> points) {
      final record = nativeRecord(points: points);
      ctx.channel.when(
        method,
        method == 'getHealthRecordSnapshot'
            ? recordSnapshot(records: [record])
            : {
                'nativeType': hr.name,
                'changes': [
                  {'type': 'upsert', 'nativeType': hr.name, 'recordId': 'native-id', 'record': record},
                ],
                if (method == 'getHealthRecordChanges') ...{
                  'nextChangesToken': 'next',
                  'changesTokenExpired': false,
                } else
                  'nextAnchor': 'next',
                'hasMore': false,
              },
      );
    }

    test('$method large-page parsing retains every legacy point field', () async {
      final points = List.generate(
        120,
        (i) => recordPoint(value: i + 40, start: 1800000000000 + i * 1000)
          ..addAll({
            'source_id': 'fixture-source',
            'device_model': 'fixture-device',
            'metadata': {
              'flag': true,
              'nested': [1, 'two'],
            },
          }),
      );
      respond(points);
      final actual = await readPoints();
      expect(actual.map((point) => point.toJson()).toList(), [
        for (final point in points) HealthDataPoint.fromHealthDataPoint(hr, point, 'BEATS_PER_MINUTE').toJson(),
      ]);
    });
    test('$method rejects a malformed point in a large page without partial success', () async {
      final points = List.generate(120, (_) => recordPoint());
      points.last['uuid'] = 'wrong-parent';
      respond(points);
      await expectLater(readPoints(), throwsFormatException);
    });
  }
  test('null token or page is a parse failure, never an empty success', () async {
    await expectLater(android.getHealthRecordChangesToken(type: hr), throwsFormatException);
    await expectLater(android.getHealthRecordSnapshot(type: hr, startTime: start, endTime: end), throwsFormatException);
  });
}

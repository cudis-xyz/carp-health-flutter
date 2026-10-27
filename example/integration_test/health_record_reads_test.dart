import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:integration_test/integration_test.dart';

// Read-only: no raw sink, saved production cursor, authorization UI or writer.
// Grant READ access to the example app before running on a prepared test device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final health = Health();
  const expectDenied = bool.fromEnvironment('HEALTH_RECORD_EXPECT_DENIED');
  final start = DateTime.now().subtract(const Duration(days: 2));
  final end = DateTime.now();
  final types = [
    HealthDataType.STEPS,
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    Platform.isIOS
        ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
        : HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.BLOOD_OXYGEN,
    if (Platform.isIOS) HealthDataType.BODY_TEMPERATURE,
    Platform.isIOS ? HealthDataType.SLEEP_ASLEEP : HealthDataType.SLEEP_SESSION,
  ];
  setUpAll(() async => health.configure());

  for (final type in types) {
    testWidgets(
      '${type.name}: native pages preserve legacy points',
      (tester) async {
        final points = <HealthDataPoint>[];
        final records = <HealthDataRecord>[];
        var pages = 0;
        String? token;
        final changesToken = Platform.isAndroid
            ? await health.getHealthRecordChangesToken(type: type)
            : null;
        do {
          expect(
            ++pages,
            lessThanOrEqualTo(200),
            reason: 'Read-only experiment page budget exhausted',
          );
          if (Platform.isIOS) {
            final page = await health.getAnchoredHealthRecords(
              type: type,
              startTime: start,
              anchor: token,
              limit: 128,
            );
            expect(
              page.hasMore,
              page.changes.isNotEmpty,
              reason: 'Only an empty HealthKit page confirms exhaustion',
            );
            records.addAll(
              page.changes
                  .where((change) => change.type == HealthChangeType.upsert)
                  .map((c) => c.record!),
            );
            token = page.nextAnchor;
            if (!page.hasMore) break;
          } else {
            final page = await health.getHealthRecordSnapshot(
              type: type,
              startTime: start,
              endTime: end,
              pageToken: pages == 1 ? null : token,
              pageSize: 128,
            );
            records.addAll(page.records);
            token = page.nextPageToken;
            if (token == null) break;
          }
        } while (true);
        for (final record in records) {
          // Anchored queries intentionally have no end. Exclude future-start
          // records from this fixed-window comparison using parent dates.
          if (Platform.isIOS && !record.dateFrom.isBefore(end)) continue;
          for (final point in record.points) {
            expect(point.uuid, record.id);
            points.add(point);
          }
        }
        final legacyTypes = type == HealthDataType.SLEEP_SESSION
            ? [
                HealthDataType.SLEEP_SESSION,
                HealthDataType.SLEEP_ASLEEP,
                HealthDataType.SLEEP_AWAKE,
                HealthDataType.SLEEP_AWAKE_IN_BED,
                HealthDataType.SLEEP_OUT_OF_BED,
                HealthDataType.SLEEP_DEEP,
                HealthDataType.SLEEP_LIGHT,
                HealthDataType.SLEEP_REM,
                HealthDataType.SLEEP_UNKNOWN,
              ]
            : type == HealthDataType.SLEEP_ASLEEP
            ? [
                HealthDataType.SLEEP_ASLEEP,
                HealthDataType.SLEEP_AWAKE,
                HealthDataType.SLEEP_IN_BED,
                HealthDataType.SLEEP_DEEP,
                HealthDataType.SLEEP_LIGHT,
                HealthDataType.SLEEP_REM,
              ]
            : [type];
        final old = await health.getHealthDataFromTypes(
          types: legacyTypes,
          startTime: start,
          endTime: end,
        );
        final current = health.removeDuplicates(points);
        expect(
          current.map((point) => jsonEncode(point.toJson())).toList()..sort(),
          old.map((point) => jsonEncode(point.toJson())).toList()..sort(),
          reason:
              'Compare a stable fixture; concurrent provider changes require a rerun',
        );
        // Counts only: never log health values, UUIDs, tokens or source details.
        // An empty data set is smoke coverage, not proof for that native type.
        // ignore: avoid_print
        print(
          'record_read_evidence type=${type.name} pages=$pages records=${records.length} points=${current.length}',
        );
        if (Platform.isAndroid) {
          final page = await health.getHealthRecordChanges(
            type: type,
            changesToken: changesToken!,
          );
          expect(page.changesTokenExpired, isFalse);
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: expectDenied,
    );
  }

  testWidgets('denied-permission fixture propagates native causes', (
    tester,
  ) async {
    for (final type in types) {
      await expectLater(
        Platform.isIOS
            ? health.getAnchoredHealthRecords(type: type, startTime: start)
            : health.getHealthRecordChangesToken(type: type),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'permission_denied')
              .having((error) => error.details, 'native cause', isA<Map>()),
        ),
      );
    }
  }, skip: !expectDenied);

  testWidgets('malformed native arguments terminate with an explicit error', (
    tester,
  ) async {
    const channel = MethodChannel('flutter_health');
    await expectLater(
      channel
          .invokeMethod<Object?>(
            Platform.isIOS
                ? 'getAnchoredHealthRecords'
                : 'getHealthRecordSnapshot',
            {
              'dataTypeKey': 'STEPS',
              'startTime': 'wrong-type',
              'pageSize': 10,
              'limit': 10,
            },
          )
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalid_argument',
        ),
      ),
    );
  });

  testWidgets('invalid cursor fails through the real native channel', (
    tester,
  ) async {
    if (Platform.isIOS) {
      for (final anchor in ['invalid-archive', 'aW52YWxpZA==']) {
        await expectLater(
          health.getAnchoredHealthRecords(
            type: HealthDataType.STEPS,
            startTime: start,
            anchor: anchor,
          ),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'invalid_cursor',
            ),
          ),
        );
      }
    } else {
      try {
        final page = await health.getHealthRecordChanges(
          type: HealthDataType.STEPS,
          changesToken: 'invalid-token',
        );
        expect(page.changesTokenExpired, isTrue);
      } on PlatformException catch (error) {
        expect(error.code, isNot(anyOf('success', '')));
        expect(error.details, isA<Map>());
      }
    }
  });
}

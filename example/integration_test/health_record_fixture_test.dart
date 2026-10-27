import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:integration_test/integration_test.dart';

// Explicitly opt in on an isolated Android emulator with READ/WRITE permissions.
// Uses only the existing writer for fixtures; never run against a user's store.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixtureDevice = String.fromEnvironment('HEALTH_RECORD_FIXTURE_DEVICE');
  testWidgets(
    'controlled native snapshot, upsert and delete preserve the old contract',
    (tester) async {
      final health = Health();
      await health.configure();
      final origin = DateTime.now().subtract(const Duration(hours: 1));
      final types = <HealthDataType, double>{
        HealthDataType.STEPS: 120,
        HealthDataType.HEART_RATE: 72,
        HealthDataType.RESTING_HEART_RATE: 60,
        HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 40,
        HealthDataType.BLOOD_OXYGEN: 98,
        HealthDataType.SLEEP_SESSION: 1,
      };
      final runId = DateTime.now().microsecondsSinceEpoch;
      String idFor(HealthDataType type, int index) =>
          'record-read-fixture-$runId-${type.name}-$index';
      HealthWriteSpec spec(
        HealthDataType type,
        double value,
        int index, {
        double version = 1,
      }) => HealthWriteSpec(
        // The existing writer creates an ASLEEP session with one stage.
        type: type == HealthDataType.SLEEP_SESSION
            ? HealthDataType.SLEEP_ASLEEP
            : type,
        value: value,
        startTime: origin.add(Duration(minutes: index * 20)),
        endTime: origin.add(Duration(minutes: index * 20, seconds: 905)),
        recordingMethod: RecordingMethod.manual,
        clientRecordId: idFor(type, index),
        clientRecordVersion: version,
      );
      final tokens = <HealthDataType, String>{};
      final nextTokens = <HealthDataType, String>{};
      final nativeIds = <HealthDataType, Set<String>>{};
      try {
        for (final type in types.keys) {
          tokens[type] = await health.getHealthRecordChangesToken(type: type);
        }
        expect(
          await health.writeHealthDataBatch([
            for (final entry in types.entries)
              for (var index = 0; index < 2; index++)
                spec(entry.key, entry.value, index),
          ]),
          isTrue,
        );
        final snapshotEnd = DateTime.now();
        for (final type in types.keys) {
          final records = <HealthDataRecord>[];
          String? pageToken;
          var pages = 0;
          do {
            expect(++pages, lessThanOrEqualTo(30));
            final page = await health.getHealthRecordSnapshot(
              type: type,
              startTime: origin,
              endTime: snapshotEnd,
              pageToken: pageToken,
              pageSize: 1,
            );
            records.addAll(page.records);
            pageToken = page.nextPageToken;
          } while (pageToken != null);
          expect(
            pages,
            greaterThanOrEqualTo(2),
            reason: 'Two fixture records must require native pagination',
          );
          expect(
            records,
            hasLength(2),
            reason: 'Run only against a clean isolated store',
          );
          expect(
            records
                .map((record) => record.dateFrom.millisecondsSinceEpoch)
                .toSet(),
            {
              origin.millisecondsSinceEpoch,
              origin.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
            },
          );
          for (final record in records) {
            final interval =
                type == HealthDataType.STEPS ||
                type == HealthDataType.HEART_RATE ||
                type == HealthDataType.SLEEP_SESSION;
            expect(
              record.dateTo.difference(record.dateFrom).inMilliseconds,
              interval ? 905000 : 0,
            );
            expect(
              record.points.every((point) => point.uuid == record.id),
              isTrue,
            );
          }
          nativeIds[type] = records.map((record) => record.id).toSet();
          expect(nativeIds[type], hasLength(2));
          final legacyTypes = type == HealthDataType.SLEEP_SESSION
              ? [HealthDataType.SLEEP_SESSION, HealthDataType.SLEEP_ASLEEP]
              : [type];
          final old = await health.getHealthDataFromTypes(
            types: legacyTypes,
            startTime: origin,
            endTime: snapshotEnd,
          );
          expect(
            records
                .expand((record) => record.points)
                .map((point) => jsonEncode(point.toJson()))
                .toList()
              ..sort(),
            old.map((point) => jsonEncode(point.toJson())).toList()..sort(),
          );

          var token = tokens[type]!;
          final upserts = <HealthRecordChange>[];
          var changePages = 0;
          while (true) {
            expect(++changePages, lessThanOrEqualTo(30));
            final page = await health.getHealthRecordChanges(
              type: type,
              changesToken: token,
            );
            expect(page.changesTokenExpired, isFalse);
            upserts.addAll(
              page.changes.where(
                (change) => change.type == HealthChangeType.upsert,
              ),
            );
            token = page.nextChangesToken;
            if (!page.hasMore) break;
          }
          expect(
            upserts.map((change) => change.recordId).toSet(),
            nativeIds[type],
          );
          expect(
            upserts
                .expand((change) => change.record!.points)
                .map((point) => jsonEncode(point.toJson()))
                .toList()
              ..sort(),
            old.map((point) => jsonEncode(point.toJson())).toList()..sort(),
          );
          nextTokens[type] = token;
        }
        // The same native record ID changes its scalar value; no synthetic UUID.
        expect(
          await health.writeHealthDataBatch([
            spec(HealthDataType.STEPS, 321, 0, version: 2),
          ]),
          isTrue,
        );
        final updated = await health.getHealthRecordChanges(
          type: HealthDataType.STEPS,
          changesToken: nextTokens[HealthDataType.STEPS]!,
        );
        expect(updated.changesTokenExpired, isFalse);
        expect(updated.changes, hasLength(1));
        final change = updated.changes.single;
        expect(change.type, HealthChangeType.upsert);
        expect(nativeIds[HealthDataType.STEPS], contains(change.recordId));
        expect(
          (change.record!.points.single.value as NumericHealthValue)
              .numericValue,
          321,
        );
        expect(
          await health.deleteByClientRecordId(
            dataTypeKey: HealthDataType.STEPS,
            clientRecordId: idFor(HealthDataType.STEPS, 0),
          ),
          isTrue,
        );
        final deleted = await health.getHealthRecordChanges(
          type: HealthDataType.STEPS,
          changesToken: updated.nextChangesToken,
        );
        expect(deleted.changesTokenExpired, isFalse);
        expect(deleted.changes, hasLength(1));
        expect(deleted.changes.single.type, HealthChangeType.delete);
        expect(deleted.changes.single.recordId, change.recordId);
        expect(deleted.changes.single.record, isNull);
      } finally {
        final cleanupFailures = <String>[];
        for (final type in types.keys) {
          for (var index = 0; index < 2; index++) {
            try {
              if (!await health.deleteByClientRecordId(
                dataTypeKey: type,
                clientRecordId: idFor(type, index),
              )) {
                cleanupFailures.add('${type.name}/$index');
              }
            } catch (error) {
              cleanupFailures.add('${type.name}/$index: ${error.runtimeType}');
            }
          }
        }
        expect(
          cleanupFailures,
          isEmpty,
          reason: 'Every fixture cleanup must be attempted',
        );
      }
    },
    skip: !Platform.isAndroid || fixtureDevice != 'isolated-emulator',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

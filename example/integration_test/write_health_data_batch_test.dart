import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:integration_test/integration_test.dart';

class _BatchCase {
  const _BatchCase(this.type, this.value, {this.interval = false});

  final HealthDataType type;
  final double value;
  final bool interval;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Health health;

  setUp(() async {
    health = Health();
    await health.configure();
  });

  testWidgets('Health Connect is available', (tester) async {
    expect(await health.isHealthConnectAvailable(), isTrue);
  });

  testWidgets('writeHealthDataBatch empty list succeeds', (tester) async {
    expect(await health.writeHealthDataBatch(const []), isTrue);
  });

  testWidgets('writeHealthDataBatch rejects specialized types', (tester) async {
    expect(
      () => health.writeHealthDataBatch([
        HealthWriteSpec(value: 1, type: HealthDataType.WORKOUT, startTime: DateTime.now()),
      ]),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => health.writeHealthDataBatch([
        HealthWriteSpec(value: 1, type: HealthDataType.ACTIVITY_INTENSITY, startTime: DateTime.now()),
      ]),
      throwsA(isA<ArgumentError>()),
    );
  });

  testWidgets('writeHealthDataBatch writes every createRecord-supported type', (tester) async {
    final cases = [
      const _BatchCase(HealthDataType.BODY_FAT_PERCENTAGE, 20),
      const _BatchCase(HealthDataType.LEAN_BODY_MASS, 50),
      const _BatchCase(HealthDataType.HEIGHT, 1.75),
      const _BatchCase(HealthDataType.WEIGHT, 70),
      const _BatchCase(HealthDataType.STEPS, 120, interval: true),
      const _BatchCase(HealthDataType.ACTIVE_ENERGY_BURNED, 50, interval: true),
      const _BatchCase(HealthDataType.HEART_RATE, 72, interval: true),
      const _BatchCase(HealthDataType.BODY_TEMPERATURE, 36.6),
      const _BatchCase(HealthDataType.BODY_WATER_MASS, 40),
      const _BatchCase(HealthDataType.BLOOD_OXYGEN, 98),
      const _BatchCase(HealthDataType.BLOOD_GLUCOSE, 95),
      const _BatchCase(HealthDataType.HEART_RATE_VARIABILITY_RMSSD, 40),
      const _BatchCase(HealthDataType.DISTANCE_DELTA, 500, interval: true),
      const _BatchCase(HealthDataType.WATER, 0.3, interval: true),
      const _BatchCase(HealthDataType.SLEEP_ASLEEP, 1, interval: true),
      const _BatchCase(HealthDataType.SLEEP_LIGHT, 3, interval: true),
      const _BatchCase(HealthDataType.SLEEP_DEEP, 4, interval: true),
      const _BatchCase(HealthDataType.SLEEP_REM, 5, interval: true),
      const _BatchCase(HealthDataType.SLEEP_OUT_OF_BED, 1, interval: true),
      const _BatchCase(HealthDataType.SLEEP_AWAKE, 2, interval: true),
      const _BatchCase(HealthDataType.SLEEP_AWAKE_IN_BED, 1, interval: true),
      const _BatchCase(HealthDataType.SLEEP_UNKNOWN, 1, interval: true),
      const _BatchCase(HealthDataType.SLEEP_SESSION, 1, interval: true),
      const _BatchCase(HealthDataType.RESTING_HEART_RATE, 60),
      const _BatchCase(HealthDataType.BASAL_ENERGY_BURNED, 1600),
      const _BatchCase(HealthDataType.FLIGHTS_CLIMBED, 3, interval: true),
      const _BatchCase(HealthDataType.RESPIRATORY_RATE, 16),
      const _BatchCase(HealthDataType.TOTAL_CALORIES_BURNED, 80, interval: true),
      _BatchCase(HealthDataType.MENSTRUATION_FLOW, MenstrualFlow.toHealthConnect(MenstrualFlow.medium).toDouble()),
      const _BatchCase(HealthDataType.SPEED, 1.5, interval: true),
    ];

    if (await health.isSkinTemperatureAvailable()) {
      cases.add(const _BatchCase(HealthDataType.SKIN_TEMPERATURE, 33, interval: true));
    }

    final origin = DateTime.now().toUtc().subtract(Duration(minutes: cases.length * 5 + 10));
    HealthWriteSpec specFor(_BatchCase item, int index) {
      final start = origin.add(Duration(minutes: index * 5));
      final end = item.interval ? start.add(const Duration(minutes: 4)) : start;
      return HealthWriteSpec(
        value: item.value,
        type: item.type,
        startTime: start,
        endTime: end,
        recordingMethod: RecordingMethod.manual,
        clientRecordId: 'batch-all-${item.type.name}',
        clientRecordVersion: 1,
      );
    }

    final failed = <String>[];
    for (var i = 0; i < cases.length; i++) {
      final item = cases[i];
      final spec = specFor(item, i);
      try {
        final success = await health.writeHealthDataBatch([spec]);
        if (!success) {
          failed.add('${item.type.name}: write returned false');
        } else {
          await health.deleteByClientRecordId(
            dataTypeKey: item.type,
            clientRecordId: spec.clientRecordId!,
          );
        }
      } on PlatformException catch (e) {
        failed.add('${item.type.name}: PlatformException(${e.code}) ${e.message}');
      } catch (e) {
        failed.add('${item.type.name}: $e');
      }
    }
    expect(failed, isEmpty, reason: 'Per-type writeDataBatch failures:\n${failed.join('\n')}');

    final mixed = [for (var i = 0; i < cases.length; i++) specFor(cases[i], i + cases.length)];
    try {
      final success = await health.writeHealthDataBatch(mixed);
      expect(success, isTrue, reason: 'Mixed writeDataBatch of ${mixed.length} supported types returned false');
    } on PlatformException catch (e) {
      fail('Mixed writeDataBatch threw PlatformException(${e.code}): ${e.message}');
    }

    for (final spec in mixed) {
      await health.deleteByClientRecordId(
        dataTypeKey: spec.type,
        clientRecordId: spec.clientRecordId!,
      );
    }
  });
}

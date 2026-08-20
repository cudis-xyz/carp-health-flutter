import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

import '../support/fixtures.dart';
import '../support/health_test_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HealthTestContext ctx;

  setUp(() async {
    ctx = HealthTestContext();
    await ctx.setUp();
  });

  tearDown(() async {
    await ctx.tearDown();
  });

  group('writeHealthDataBatch', () {
    test('returns true for an empty list', () async {
      final success = await ctx.health.writeHealthDataBatch([]);

      expect(success, isTrue);
      expect(ctx.channel.calls.where((call) => call.method.startsWith('write')), isEmpty);
    });

    test('rejects workout type', () {
      expect(
        () => ctx.health.writeHealthDataBatch([
          HealthWriteSpec(
            value: 1,
            type: HealthDataType.WORKOUT,
            startTime: HealthFixtures.start,
            endTime: HealthFixtures.end,
          ),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'falls back to sequential writes off Android',
      () async {
        ctx.channel.when('writeData', true);

        final success = await ctx.health.writeHealthDataBatch([
          HealthWriteSpec(
            value: 80,
            type: HealthDataType.HEART_RATE,
            unit: HealthDataUnit.BEATS_PER_MINUTE,
            startTime: HealthFixtures.start,
            endTime: HealthFixtures.end,
            recordingMethod: RecordingMethod.manual,
            clientRecordId: 'client-id-1',
            clientRecordVersion: 1,
          ),
          HealthWriteSpec(
            value: 99,
            type: HealthDataType.SLEEP_IN_BED,
            startTime: HealthFixtures.start,
            endTime: HealthFixtures.end,
          ),
        ]);

        expect(success, isTrue);
        final calls = ctx.channel.calls.where((call) => call.method == 'writeData').toList();
        expect(calls, hasLength(2));
        final firstArgs = Map<String, dynamic>.from(calls.first.arguments as Map);
        expect(firstArgs['value'], 80);
        expect(firstArgs['clientRecordId'], 'client-id-1');
        expect(firstArgs['clientRecordVersion'], 1);
        final secondArgs = Map<String, dynamic>.from(calls.last.arguments as Map);
        expect(secondArgs['value'], 0);
      },
      skip: Platform.isAndroid ? 'Not applicable on Android hosts' : null,
    );

    test(
      'sends a single writeDataBatch call on Android',
      () async {
        ctx.channel.when('getHealthConnectSdkStatus', HealthConnectSdkStatus.sdkAvailable.nativeValue);
        ctx.channel.when('writeDataBatch', true);

        final success = await ctx.health.writeHealthDataBatch([
          HealthWriteSpec(
            value: 12,
            type: HealthDataType.STEPS,
            startTime: HealthFixtures.start,
            endTime: HealthFixtures.end,
            recordingMethod: RecordingMethod.manual,
            clientRecordId: 'steps-0',
            clientRecordVersion: 1,
          ),
          HealthWriteSpec(
            value: 8,
            type: HealthDataType.STEPS,
            startTime: HealthFixtures.start,
            endTime: HealthFixtures.end,
            recordingMethod: RecordingMethod.manual,
            clientRecordId: 'steps-1',
            clientRecordVersion: 1,
          ),
        ]);

        expect(success, isTrue);
        final calls = ctx.channel.calls.where((call) => call.method == 'writeDataBatch').toList();
        expect(calls, hasLength(1));
        final payload = List<dynamic>.from((calls.single.arguments as Map)['data'] as List);
        expect(payload, hasLength(2));
        final firstArgs = Map<String, dynamic>.from(payload.first as Map);
        expect(firstArgs['dataTypeKey'], HealthDataType.STEPS.name);
        expect(firstArgs['value'], 12);
        expect(firstArgs['clientRecordId'], 'steps-0');
      },
      skip: Platform.isAndroid ? null : 'Android batch path',
    );
  });
}

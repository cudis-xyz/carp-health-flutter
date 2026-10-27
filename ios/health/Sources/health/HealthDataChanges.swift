import Flutter
import HealthKit

private struct HealthRecordReadFailure: Error {
    let code: String
}

extension HealthDataReader {
    // Shared with strict anchored reads; preserve the legacy dictionary contracts.
    func quantitySampleToDataPoint(_ sample: HKQuantitySample, unit: HKUnit?) -> NSDictionary {
        return [
            "uuid": "\(sample.uuid)",
            "value": sample.quantity.doubleValue(
                for: unit ?? HKUnit.internationalUnit()
            ),
            "date_from": Int(sample.startDate.timeIntervalSince1970 * 1000),
            "date_to": Int(sample.endDate.timeIntervalSince1970 * 1000),
            "source_id": sample.sourceRevision.source.bundleIdentifier,
            "source_name": sample.sourceRevision.source.name,
            "recording_method":
                (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true)
                ? HealthConstants.RecordingMethod.manual.rawValue
                : HealthConstants.RecordingMethod.automatic.rawValue,
            "dataUnitKey": unit?.unitString as Any,
            "metadata": HealthUtilities.sanitizeMetadata(sample.metadata),
        ]
    }

    func categorySampleToDataPoint(_ sample: HKCategorySample) -> NSDictionary {
        return [
            "uuid": "\(sample.uuid)",
            "value": sample.value,
            "date_from": Int(sample.startDate.timeIntervalSince1970 * 1000),
            "date_to": Int(sample.endDate.timeIntervalSince1970 * 1000),
            "source_id": sample.sourceRevision.source.bundleIdentifier,
            "source_name": sample.sourceRevision.source.name,
            "recording_method":
                (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true)
                ? HealthConstants.RecordingMethod.manual.rawValue
                : HealthConstants.RecordingMethod.automatic.rawValue,
            "metadata": HealthUtilities.sanitizeMetadata(sample.metadata),
        ]
    }

    /// One-shot anchored read. The caller owns anchor persistence and scope.
    @available(iOS 15.4, *)
    func getAnchoredHealthRecords(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // The query and full-page conversion run outside the platform main thread.
        Task.detached(priority: .utility) {
            var stage = "arguments"
            do {
                let units = [
                    HealthConstants.STEPS: "COUNT",
                    HealthConstants.HEART_RATE: "BEATS_PER_MINUTE",
                    HealthConstants.RESTING_HEART_RATE: "BEATS_PER_MINUTE",
                    HealthConstants.HEART_RATE_VARIABILITY_SDNN: "MILLISECOND",
                    HealthConstants.BLOOD_OXYGEN: "PERCENT",
                    HealthConstants.BODY_TEMPERATURE: "DEGREE_CELSIUS",
                    HealthConstants.SLEEP_ASLEEP: "MINUTE",
                ]
                guard let args = call.arguments as? [String: Any],
                      let typeKey = args["dataTypeKey"] as? String,
                      let start = args["startTime"] as? Int,
                      abs(Double(start)) <= 8_640_000_000_000_000,
                      let limit = args["limit"] as? Int, limit > 0
                else { throw HealthRecordReadFailure(code: "invalid_argument") }
                guard let unitKey = units[typeKey], let sampleType = self.dataTypesDict[typeKey] else {
                    throw HealthRecordReadFailure(code: "unsupported_type")
                }
                guard args["dataUnitKey"] as? String == unitKey, let unit = self.unitDict[unitKey] else {
                    throw HealthRecordReadFailure(code: "invalid_argument")
                }
                guard HKHealthStore.isHealthDataAvailable() else {
                    throw HealthRecordReadFailure(code: "health_data_unavailable")
                }
                stage = "anchor_decode"
                var anchor: HKQueryAnchor?
                if let encoded = args["anchor"], !(encoded is NSNull) {
                    guard let string = encoded as? String, !string.isEmpty,
                          let data = Data(base64Encoded: string),
                          let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
                    else { throw HealthRecordReadFailure(code: "invalid_cursor") }
                    anchor = decoded
                }
                let predicate = HKQuery.predicateForSamples(
                    withStart: Date(timeIntervalSince1970: Double(start) / 1000),
                    end: nil, options: .strictStartDate
                )
                let descriptor = HKAnchoredObjectQueryDescriptor(
                    predicates: [HKSamplePredicate.sample(type: sampleType, predicate: predicate)],
                    anchor: anchor, limit: limit
                )
                stage = "query"
                let page = try await descriptor.result(for: self.healthStore)
                try Task.checkCancellation()
                stage = "conversion"
                let sleepTypes = [
                    HealthConstants.SLEEP_IN_BED, HealthConstants.SLEEP_ASLEEP,
                    HealthConstants.SLEEP_AWAKE, HealthConstants.SLEEP_LIGHT,
                    HealthConstants.SLEEP_DEEP, HealthConstants.SLEEP_REM,
                ]
                var changes = try page.addedSamples.map { sample -> [String: Any] in
                    guard sample.sampleType == sampleType,
                          sample.startDate <= sample.endDate,
                          sample.startDate.timeIntervalSince1970.isFinite,
                          sample.endDate.timeIntervalSince1970.isFinite,
                          abs(sample.startDate.timeIntervalSince1970) <= 8_640_000_000_000,
                          abs(sample.endDate.timeIntervalSince1970) <= 8_640_000_000_000
                    else { throw HealthRecordReadFailure(code: "health_read_error") }
                    let point: NSDictionary
                    let pointType: String
                    if let quantity = sample as? HKQuantitySample, typeKey != HealthConstants.SLEEP_ASLEEP {
                        guard quantity.quantity.is(compatibleWith: unit) else {
                            throw HealthRecordReadFailure(code: "health_read_error")
                        }
                        point = self.quantitySampleToDataPoint(quantity, unit: unit)
                        pointType = typeKey
                    } else if let category = sample as? HKCategorySample,
                              typeKey == HealthConstants.SLEEP_ASLEEP,
                              sleepTypes.indices.contains(category.value) {
                        point = self.categorySampleToDataPoint(category)
                        pointType = sleepTypes[category.value]
                    } else {
                        throw HealthRecordReadFailure(code: "health_read_error")
                    }
                    guard let value = point["value"] as? NSNumber, value.doubleValue.isFinite,
                          var fields = point as? [String: Any]
                    else { throw HealthRecordReadFailure(code: "health_read_error") }
                    fields["dataTypeKey"] = pointType
                    fields["dataUnitKey"] = unitKey
                    let id = sample.uuid.uuidString
                    return [
                        "type": "upsert", "nativeType": typeKey, "recordId": id,
                        "record": [
                            "id": id, "nativeType": typeKey,
                            "date_from": Int(sample.startDate.timeIntervalSince1970 * 1000),
                            "date_to": Int(sample.endDate.timeIntervalSince1970 * 1000),
                            "points": [fields],
                        ],
                    ]
                }
                changes.append(contentsOf: page.deletedObjects.map {
                    ["type": "delete", "nativeType": typeKey, "recordId": $0.uuid.uuidString]
                })
                stage = "anchor_encode"
                let nextAnchor = try NSKeyedArchiver.archivedData(
                    withRootObject: page.newAnchor, requiringSecureCoding: true
                ).base64EncodedString()
                // A limit is an upper bound; only an empty page confirms exhaustion.
                let hasMore = !page.addedSamples.isEmpty || !page.deletedObjects.isEmpty
                if hasMore, let anchor, anchor.isEqual(page.newAnchor) {
                    throw HealthRecordReadFailure(code: "health_read_error")
                }
                let payload: [String: Any] = [
                    "nativeType": typeKey, "changes": changes,
                    "nextAnchor": nextAnchor, "hasMore": hasMore,
                ]
                try Task.checkCancellation()
                await MainActor.run { result(payload) }
            } catch {
                let native = error as NSError
                let code: String
                if let failure = error as? HealthRecordReadFailure {
                    code = failure.code
                } else if error is CancellationError {
                    code = "cancelled"
                } else if stage == "anchor_decode" {
                    code = "invalid_cursor"
                } else if native.domain == HKErrorDomain,
                          native.code == HKError.Code.errorAuthorizationDenied.rawValue ||
                          native.code == HKError.Code.errorAuthorizationNotDetermined.rawValue {
                    code = "permission_denied"
                } else {
                    code = "health_read_error"
                }
                // HealthKit messages can contain query arguments; retain domain/code only.
                let details: [String: Any] = [
                    "method": call.method, "stage": stage,
                    "domain": native.domain, "code": native.code,
                ]
                await MainActor.run {
                    result(FlutterError(code: code, message: "Native anchored read failed", details: details))
                }
            }
        }
    }
}

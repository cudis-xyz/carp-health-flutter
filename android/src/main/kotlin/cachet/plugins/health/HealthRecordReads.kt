package cachet.plugins.health

import android.content.Context
import android.health.connect.HealthConnectException
import android.os.Build
import android.os.Handler
import androidx.health.connect.client.records.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.reflect.KClass

/** A read-only envelope; all point values/UUIDs reuse legacy conversion. */
internal fun HealthDataConverter.convertRecordEnvelope(record: Record, dataType: String): Map<String, Any?> {
    check(HealthConstants.mapToType[dataType]?.isInstance(record) == true) { "Record type mismatch" }
    check(record.metadata.id.isNotEmpty()) { "Missing native record ID" }
    val (from, to) = when (record) {
        is StepsRecord -> record.startTime to record.endTime
        is HeartRateRecord -> record.startTime to record.endTime
        is SleepSessionRecord -> record.startTime to record.endTime
        is RestingHeartRateRecord -> record.time to record.time
        is HeartRateVariabilityRmssdRecord -> record.time to record.time
        is OxygenSaturationRecord -> record.time to record.time
        else -> error("Unsupported record timestamps")
    }
    fun typed(points: List<Map<String, Any?>>, type: String): List<Map<String, Any?>> {
        val unit = healthRecordReadUnit(type)
        return points.map { point ->
            check((point["value"] as? Number)?.toDouble()?.isFinite() == true) { "Invalid native value" }
            point + mapOf("dataTypeKey" to type, "dataUnitKey" to unit)
        }
    }
    val points = typed(convertRecord(record, dataType), dataType).toMutableList()
    if (record is SleepSessionRecord) {
        for (stage in record.stages) {
            val type = HealthConstants.mapSleepStageToType[stage.stage] ?: error("Unknown native sleep stage")
            // Stage recording_method stays absent, as in the legacy stage read.
            points.addAll(typed(convertRecordStage(stage, type, record.metadata), type))
        }
    }
    return mapOf(
        "id" to record.metadata.id, "nativeType" to dataType,
        "date_from" to from.toEpochMilli(), "date_to" to to.toEpochMilli(), "points" to points
    )
}

// Shared only by the new strict reads. Legacy error/permission behavior is unchanged.
internal fun healthRecordReadType(call: MethodCall): Pair<String, KClass<out Record>> {
    val type = (call.arguments as? Map<*, *>)?.get("dataTypeKey")
    require(type is String) { "Missing dataTypeKey" }
    if (type !in setOf(
            HealthConstants.STEPS, HealthConstants.HEART_RATE, HealthConstants.RESTING_HEART_RATE,
            HealthConstants.HEART_RATE_VARIABILITY_RMSSD, HealthConstants.BLOOD_OXYGEN,
            HealthConstants.SLEEP_SESSION
        )) throw UnsupportedOperationException("Unsupported record read type: $type")
    if (call.method != "getHealthRecordChangesToken") {
        require((call.arguments as? Map<*, *>)?.get("dataUnitKey") == healthRecordReadUnit(type)) { "Invalid dataUnitKey" }
    }
    return type to checkNotNull(HealthConstants.mapToType[type])
}

internal fun healthRecordReadUnit(type: String): String = when (type) {
    HealthConstants.STEPS -> "COUNT"
    HealthConstants.HEART_RATE, HealthConstants.RESTING_HEART_RATE -> "BEATS_PER_MINUTE"
    HealthConstants.HEART_RATE_VARIABILITY_RMSSD -> "MILLISECOND"
    HealthConstants.BLOOD_OXYGEN -> "PERCENT"
    else -> "MINUTE" // Sleep session and stages; callers validate supported types.
}

internal fun healthRecordReadError(result: Result, error: Throwable, method: String, stage: String = "initialization") {
    val nativeCode = if (Build.VERSION.SDK_INT >= 34) {
        generateSequence(error) { it.cause }.filterIsInstance<HealthConnectException>()
            .firstOrNull()?.errorCode
    } else null
    val code = when {
        error is CancellationException -> "cancelled"
        error.isHealthConnectRateLimited() -> HEALTH_CONNECT_RATE_LIMITED_ERROR
        error is SecurityException -> "permission_denied"
        error is UnsupportedOperationException -> "unsupported_type"
        error is IllegalArgumentException -> "invalid_argument"
        else -> "health_read_error"
    }
    // Do not expose provider messages: some include complete tokens or record data.
    result.error(code, "Native record read failed", mapOf(
        "method" to method, "stage" to stage, "exceptionType" to error.javaClass.name,
        "causeType" to error.cause?.javaClass?.name, "nativeErrorCode" to nativeCode
    ))
}

internal fun launchHealthRecordRead(
    scope: CoroutineScope, context: Context, call: MethodCall, result: Result,
    read: suspend ((String) -> Unit) -> Any
) {
    val replied = AtomicBoolean(false)
    val handler = Handler(context.mainLooper)
    var stage = "arguments"
    fun finish(payload: Any? = null, error: Throwable? = null) {
        if (!replied.compareAndSet(false, true)) return
        val failedStage = stage
        handler.post {
            if (error == null) result.success(payload) else healthRecordReadError(result, error, call.method, failedStage)
        }
    }
    // Includes conversion; the plugin's existing scope uses Dispatchers.Main.
    scope.launch(Dispatchers.IO) {
        try {
            val payload = read { stage = it }
            ensureActive()
            finish(payload)
        } catch (error: CancellationException) {
            finish(error = error)
            throw error
        } catch (error: Exception) {
            finish(error = error)
        }
    }.invokeOnCompletion { error ->
        // Also completes a request launched into an already cancelled scope.
        if (error != null) finish(error = error)
    }
}

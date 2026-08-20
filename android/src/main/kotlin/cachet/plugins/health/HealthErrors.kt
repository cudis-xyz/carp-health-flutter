package cachet.plugins.health

internal const val HEALTH_CONNECT_RATE_LIMITED_ERROR = "rate_limited"
private const val HEALTH_CONNECT_ERROR_RATE_LIMIT_EXCEEDED = 7

internal fun Throwable.isHealthConnectRateLimited(): Boolean {
        var error: Throwable? = this
        while (error != null) {
                if (error.isHealthConnectRateLimitCode()) {
                        return true
                }
                val message = error.message.orEmpty()
                if (message.contains("Rate limited request quota", ignoreCase = true) ||
                        message.contains("API call quota exceeded", ignoreCase = true)
                ) {
                        return true
                }
                error = error.cause
        }
        return false
}

private fun Throwable.isHealthConnectRateLimitCode(): Boolean {
        val errorCode =
                runCatching { javaClass.getMethod("getErrorCode").invoke(this) as? Number }
                        .getOrNull()
                        ?.toInt()
        return errorCode == HEALTH_CONNECT_ERROR_RATE_LIMIT_EXCEEDED
}

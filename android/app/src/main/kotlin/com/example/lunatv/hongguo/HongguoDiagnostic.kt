// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.lunatv.hongguo

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedQueue

data class DiagnosticEvent(
    val timestamp: Long = System.currentTimeMillis(),
    val level: String, // INFO, WARN, ERROR
    val stage: String, // device_register, stream_resolver, local_server, player
    val code: String,  // DEVICE_REGISTER_OK, DEVICE_REGISTER_INVALID, RESOLVE_OK, RESOLVE_EMPTY, LOCAL_SERVER_OK, PLAYER_ERROR
    val message: String,
    val details: Map<String, Any?> = emptyMap()
) {
    fun format(): String {
        val timeStr = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault()).format(Date(timestamp))
        val detailStr = if (details.isNotEmpty()) " | " + details.entries.joinToString(" ") { "${it.key}=${it.value}" } else ""
        return "[$timeStr][$level][$stage][$code] $message$detailStr"
    }

    fun toMap(): Map<String, Any?> {
        return mapOf(
            "timestamp" to timestamp,
            "level" to level,
            "stage" to stage,
            "code" to code,
            "message" to message,
            "formatted" to format()
        )
    }
}

data class DiagnosticReport(
    val stage: String = "idle",
    val code: String = "NOT_RUN",
    val httpStatus: Int? = null,
    val responseBytes: Int? = null,
    val networkReason: String? = null,
    val elapsedMs: Long? = null,
    val summary: String = "等待起播",
    val lastError: String? = null,
    val updatedAt: Long = System.currentTimeMillis()
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "stage" to stage,
            "code" to code,
            "httpStatus" to httpStatus,
            "responseBytes" to responseBytes,
            "networkReason" to networkReason,
            "elapsedMs" to elapsedMs,
            "summary" to summary,
            "lastError" to lastError,
            "updatedAt" to updatedAt
        )
    }
}

object HongguoDiagnostic {
    private const val MAX_LOGS = 200
    private val logs = ConcurrentLinkedQueue<DiagnosticEvent>()

    @Volatile
    var currentReport: DiagnosticReport = DiagnosticReport()
        private set

    @Volatile
    var currentSeriesTitle: String = ""

    @Volatile
    var currentEpisode: Int = 1

    @Volatile
    var currentVid: String = ""

    fun setContext(title: String, episode: Int, vid: String) {
        currentSeriesTitle = title
        currentEpisode = episode
        currentVid = vid
        log("INFO", "context", "SWITCH_EPISODE", "切换剧集: $title 第${episode}集 (vid=$vid)")
    }

    fun log(level: String, stage: String, code: String, message: String, details: Map<String, Any?> = emptyMap()) {
        val event = DiagnosticEvent(
            level = level,
            stage = stage,
            code = code,
            message = message,
            details = details
        )
        logs.add(event)
        while (logs.size > MAX_LOGS) {
            logs.poll()
        }
        val priority = when (level) {
            "ERROR" -> android.util.Log.ERROR
            "WARN" -> android.util.Log.WARN
            else -> android.util.Log.INFO
        }
        android.util.Log.println(priority, "HongguoDiagnostic", event.format())
    }

    fun updateReport(
        stage: String,
        code: String,
        httpStatus: Int? = null,
        responseBytes: Int? = null,
        networkReason: String? = null,
        elapsedMs: Long? = null,
        summary: String,
        lastError: String? = null
    ) {
        currentReport = DiagnosticReport(
            stage = stage,
            code = code,
            httpStatus = httpStatus,
            responseBytes = responseBytes,
            networkReason = networkReason,
            elapsedMs = elapsedMs,
            summary = summary,
            lastError = lastError,
            updatedAt = System.currentTimeMillis()
        )
    }

    fun getLogs(): List<DiagnosticEvent> = logs.toList()

    fun getFormattedLogs(): String {
        return logs.joinToString("\n") { it.format() }
    }

    fun getDiagnosticReportSummary(): String {
        val rep = currentReport
        val timeStr = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(rep.updatedAt))
        val sb = StringBuilder()
        sb.appendLine("=== 短剧播放诊断报告 [$timeStr] ===")
        if (currentSeriesTitle.isNotEmpty()) {
            sb.appendLine("剧集信息: $currentSeriesTitle 第${currentEpisode}集 (vid: $currentVid)")
        }
        sb.appendLine("当前阶段: ${rep.stage}")
        sb.appendLine("判定结果: ${rep.code}")
        sb.appendLine("诊断判定: ${rep.summary}")
        if (rep.httpStatus != null) sb.appendLine("HTTP状态: ${rep.httpStatus}")
        if (rep.responseBytes != null) sb.appendLine("响应体大小: ${rep.responseBytes} 字节")
        if (!rep.networkReason.isNullOrEmpty()) sb.appendLine("网络原因: ${rep.networkReason}")
        if (rep.elapsedMs != null) sb.appendLine("耗时: ${rep.elapsedMs} ms")
        if (!rep.lastError.isNullOrEmpty()) sb.appendLine("最后异常: ${rep.lastError}")
        sb.appendLine("===============================")
        return sb.toString().trim()
    }

    fun clear() {
        logs.clear()
        currentReport = DiagnosticReport(summary = "日记已清空")
    }
}

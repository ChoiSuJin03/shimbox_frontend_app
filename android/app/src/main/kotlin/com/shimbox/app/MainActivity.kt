package com.shimbox.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

// Health Connect
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId

// ★ 워치 → 폰 메시지 브로드캐스트 액션 (FallMessageService에서 보냄)
import com.shimbox.app.wear.FallMessageService

class MainActivity : FlutterFragmentActivity() {

    // ========== Health Connect (기존) ==========
    // Health Connect client (lazy) — getSdkStatus 사용, 패키지명은 literal 로
    private val healthClient: HealthConnectClient? by lazy {
        val status = HealthConnectClient.getSdkStatus(
            this,
            "com.google.android.apps.healthdata" // DEFAULT_PROVIDER_PACKAGE_NAME 대신 literal
        )
        if (status == HealthConnectClient.SDK_AVAILABLE) {
            HealthConnectClient.getOrCreate(this)
        } else {
            null
        }
    }

    // ========== ★ Wear 낙상 이벤트용 EventChannel ==========
    private val FALL_CHANNEL = "shimbox/fall_events"
    private var fallSink: EventChannel.EventSink? = null

    // 폰 서비스(FallMessageService)가 보낸 브로드캐스트 → Dart로 전달
    private val fallReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == FallMessageService.ACTION_FALL_EVENT) {
                val payload = intent.getStringExtra(FallMessageService.EXTRA_PAYLOAD) ?: "{}"
                fallSink?.success(payload) // JSON 문자열 그대로 Flutter로 push
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ========== (기존) MethodChannel: "shimbox/health" ==========
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shimbox/health")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSamsungStepsTotal" -> {
                        val startMs = (call.argument<Number>("start") ?: 0L).toLong()
                        val endMs = (call.argument<Number>("end") ?: 0L).toLong()
                        if (healthClient == null) {
                            result.success(0)
                            return@setMethodCallHandler
                        }
                        lifecycleScope.launch {
                            try {
                                val total = getStepsTotalViaHealthConnect(startMs, endMs)
                                result.success(total)
                            } catch (_: Exception) {
                                result.success(0)
                            }
                        }
                    }
                    "debugStepOrigins" -> {
                        val startMs = (call.argument<Number>("start") ?: 0L).toLong()
                        val endMs = (call.argument<Number>("end") ?: 0L).toLong()
                        if (healthClient == null) {
                            result.success("[]")
                            return@setMethodCallHandler
                        }
                        lifecycleScope.launch {
                            try {
                                val json = debugStepOriginsJson(startMs, endMs)
                                result.success(json)
                            } catch (_: Exception) {
                                result.success("[]")
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ========== ★ 추가: EventChannel: "shimbox/fall_events" ==========
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, FALL_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    fallSink = events
                    // 브로드캐스트 수신 시작
                    registerReceiver(
                        fallReceiver,
                        IntentFilter(FallMessageService.ACTION_FALL_EVENT)
                    )
                }

                override fun onCancel(args: Any?) {
                    // 수신 해제
                    unregisterReceiver(fallReceiver)
                    fallSink = null
                }
            })
    }

    // ===== Health Connect helpers (기존) =====
    private suspend fun getStepsTotalViaHealthConnect(startMs: Long, endMs: Long): Int {
        val client = healthClient ?: return 0
        val start = Instant.ofEpochMilli(startMs)
        val end = Instant.ofEpochMilli(endMs)

        val response = client.readRecords(
            ReadRecordsRequest(
                StepsRecord::class,
                timeRangeFilter = TimeRangeFilter.between(start, end)
            )
        )

        // 삼성 오리진 우선(없으면 전체)
        val samsungOnly = response.records.filter { r ->
            val p = r.metadata.dataOrigin.packageName.lowercase()
            p.contains("samsung") || p.contains("shealth")
        }
        val target = if (samsungOnly.isNotEmpty()) samsungOnly else response.records

        var sum = 0L
        for (rec in target) sum += rec.count
        return sum.toInt()
    }

    private suspend fun debugStepOriginsJson(startMs: Long, endMs: Long): String {
        val client = healthClient ?: return "[]"
        val start = Instant.ofEpochMilli(startMs)
        val end = Instant.ofEpochMilli(endMs)

        val response = client.readRecords(
            ReadRecordsRequest(
                StepsRecord::class,
                timeRangeFilter = TimeRangeFilter.between(start, end)
            )
        )

        val items = response.records.map { r ->
            val origin = r.metadata.dataOrigin.packageName
            val from = r.startTime.atZone(ZoneId.systemDefault()).toLocalDateTime()
            val to = r.endTime.atZone(ZoneId.systemDefault()).toLocalDateTime()
            "$origin | $from ~ $to | count=${r.count}"
        }.toSet().toList()

        return items.joinToString(prefix = "[", postfix = "]") { s ->
            "\"${s.replace("\"", "\\\"")}\""
        }
    }
}

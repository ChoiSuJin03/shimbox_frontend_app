package com.shimbox.app.wear

import android.content.Intent
import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import java.nio.charset.StandardCharsets

class FallMessageService : WearableListenerService() {

    companion object {
        const val ACTION_FALL_EVENT = "com.shimbox.app.FALL_EVENT"
        const val EXTRA_PAYLOAD = "payload"
        const val FALL_PATH = "/fall_event"
        private const val TAG = "FallPhone"
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "FallMessageService onCreate()")
    }

    override fun onDestroy() {
        Log.i(TAG, "FallMessageService onDestroy()")
        super.onDestroy()
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        Log.i(TAG, "onMessageReceived() path=${messageEvent.path}, dataSize=${messageEvent.data?.size ?: 0}")

        if (messageEvent.path == FALL_PATH) {
            val json = try {
                String(messageEvent.data ?: ByteArray(0), StandardCharsets.UTF_8)
            } catch (e: Exception) {
                Log.e(TAG, "Payload decode error: ${e.message}", e)
                "{}"
            }

            Log.i(TAG, "Received /fall_event: $json")

            // 앱 프로세스로 브로드캐스트 → MainActivity(EventChannel)에서 Dart로 전달
            try {
                sendBroadcast(Intent(ACTION_FALL_EVENT).apply {
                    `package` = packageName
                    putExtra(EXTRA_PAYLOAD, json)
                })
                Log.i(TAG, "Broadcast sent (action=$ACTION_FALL_EVENT)")
            } catch (e: Exception) {
                Log.e(TAG, "Broadcast failed: ${e.message}", e)
            }

            // (원하면 백그라운드에서도 알림 띄우기)
            // notifyPhoneFall()
        } else {
            Log.i(TAG, "Ignored path: ${messageEvent.path}")
            super.onMessageReceived(messageEvent)
        }
    }

    /*
    // 필요 시 백그라운드 알림 켜기
    private fun notifyPhoneFall() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val chId = "fall_phone_channel"
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val ch = android.app.NotificationChannel(
                chId, "낙상 감지(폰)", android.app.NotificationManager.IMPORTANCE_HIGH
            )
            nm.createNotificationChannel(ch)
        }
        val notif = androidx.core.app.NotificationCompat.Builder(this, chId)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("워치에서 낙상 감지")
            .setContentText("앱을 열어 상태를 확인하세요.")
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        nm.notify(7001, notif)
        Log.i(TAG, "Phone notification shown")
    }
    */
}

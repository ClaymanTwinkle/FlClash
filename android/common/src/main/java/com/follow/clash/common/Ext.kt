package com.follow.clash.common

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlin.reflect.KClass

val KClass<*>.intent: Intent
    get() = Intent(GlobalState.application, this.java)

val ComponentName.intent: Intent
    get() = Intent().apply {
        component = this@intent
    }

val QuickAction.action: String
    get() = "${GlobalState.application.packageName}.action.${this.name}"

val QuickAction.shortcutId: String
    get() = name.lowercase()

val QuickAction.quickIntent: Intent
    get() = Components.quickActionActivity.intent.apply {
        action = this@quickIntent.action
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
    }

val BroadcastAction.action: String
    get() = "${GlobalState.application.packageName}.intent.action.${this.name}"

fun BroadcastAction.sendBroadcast() {
    val broadcastAction = action
    val intent = Intent(broadcastAction).apply {
        component = Components.serviceBroadcastReceiver
    }
    GlobalState.application.sendBroadcast(
        intent,
        GlobalState.receiveBroadcastPermission,
    )
}

val Intent.toPendingIntent: PendingIntent
    get() = PendingIntent.getActivity(
        GlobalState.application,
        0,
        this,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

fun Context.ensureNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
        return
    }
    val manager = getSystemService(NotificationManager::class.java) ?: return
    if (manager.getNotificationChannel(GlobalState.NOTIFICATION_CHANNEL) != null) {
        return
    }
    manager.createNotificationChannel(
        NotificationChannel(
            GlobalState.NOTIFICATION_CHANNEL,
            getString(R.string.service_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ),
    )
}

fun Service.startForeground(notification: Notification) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        startForeground(
            GlobalState.NOTIFICATION_ID,
            notification,
            FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
    } else {
        startForeground(GlobalState.NOTIFICATION_ID, notification)
    }
}

// Below Android 13 a plain registerReceiver is open to every app. ContextCompat keeps a
// not-exported receiver private there too, behind a signature-level permission.
fun Context.registerReceiverCompat(
    receiver: BroadcastReceiver,
    filter: IntentFilter,
    exported: Boolean = false,
): Intent? = ContextCompat.registerReceiver(
    this,
    receiver,
    filter,
    if (exported) ContextCompat.RECEIVER_EXPORTED else ContextCompat.RECEIVER_NOT_EXPORTED,
)

fun Context.receiveBroadcastFlow(
    exported: Boolean = false,
    configure: IntentFilter.() -> Unit,
): Flow<Intent> = callbackFlow {
    val filter = IntentFilter().apply(configure)
    val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (context == null || intent == null) return
            trySend(intent)
        }
    }
    registerReceiverCompat(receiver, filter, exported)
    awaitClose {
        // Cancellation reaches here on another thread, so a Service whose
        // onDestroy cancelled the collector may already have had the system
        // drop its leaked receivers, and unregistering again then throws.
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
        }
    }
}

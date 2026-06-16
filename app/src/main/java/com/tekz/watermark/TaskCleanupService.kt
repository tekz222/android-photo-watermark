package com.tekz.watermark

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * Started while the app is open. When the user swipes the app away (closes it),
 * [onTaskRemoved] fires and we wipe the saved project so the next launch starts
 * fresh. Merely minimizing / backgrounding does NOT trigger this, so state is
 * kept then.
 */
class TaskCleanupService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onTaskRemoved(rootIntent: Intent?) {
        ProjectStore.clear(applicationContext)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}

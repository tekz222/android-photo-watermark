package com.tekz.watermark

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Shared state for the batch-save job. The UI fills in the inputs and starts
 * [WatermarkService]; the service drains [next] and publishes [progress], which
 * the UI observes. Photos can be added while the job runs (see [addPhotos]).
 */
object WatermarkJob {

    data class Progress(
        val running: Boolean = false,
        val processed: Int = 0,
        val total: Int = 0,
        val saved: Int = 0,
        val failed: Int = 0,
        val finished: Boolean = false
    )

    val progress = MutableStateFlow(Progress())

    // Inputs (set before starting the service).
    @Volatile var bottomLogoUris: List<Uri> = emptyList()
    @Volatile var topLeftLogoUris: List<Uri> = emptyList()
    @Volatile var cornerLogoUri: Uri? = null
    @Volatile var logoHeightFraction = 0.12f
    @Volatile var leftMarginFraction = 0.02f
    @Volatile var rowOpacity = 1f
    @Volatile var bottomMarginFraction = 0.01f
    @Volatile var topMarginFraction = 0.01f
    @Volatile var cornerHeightFraction = 0.12f
    @Volatile var cornerMarginFraction = 0.02f
    @Volatile var centered = false
    @Volatile var albumName = "Watermarked"

    private val lock = Any()
    private val all = LinkedHashSet<Uri>()
    private val done = LinkedHashSet<Uri>()

    fun reset(photos: List<Uri>) = synchronized(lock) {
        all.clear(); all.addAll(photos); done.clear()
    }

    /** Adds more photos to the running job (deduplicated). */
    fun addPhotos(photos: List<Uri>) = synchronized(lock) { all.addAll(photos) }

    /** Returns the next unprocessed photo (marking it done), or null when empty. */
    fun next(): Uri? = synchronized(lock) {
        val u = all.firstOrNull { it !in done } ?: return null
        done.add(u); u
    }

    fun total(): Int = synchronized(lock) { all.size }
    fun doneCount(): Int = synchronized(lock) { done.size }
}

class WatermarkService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        startForeground(NOTIF_ID, buildNotification(WatermarkJob.doneCount(), WatermarkJob.total()))
        scope.launch { runJob() }
        return START_NOT_STICKY
    }

    private fun runJob() {
        val resolver = contentResolver
        val cache = HashMap<Uri, Bitmap?>()
        fun bmp(uri: Uri) = cache.getOrPut(uri) { WatermarkEngine.loadBitmap(resolver, uri) }

        val logos = WatermarkJob.bottomLogoUris.mapNotNull { bmp(it) }
        val topLeft = WatermarkJob.topLeftLogoUris.mapNotNull { bmp(it) }
        val corner = WatermarkJob.cornerLogoUri?.let { bmp(it) }

        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        var saved = 0
        var failed = 0
        var index = 0

        publish(true, saved, failed, finished = false)

        while (true) {
            val photoUri = WatermarkJob.next() ?: break
            val photo = WatermarkEngine.loadBitmap(resolver, photoUri, maxDimension = 8192)
            if (photo == null) {
                failed++
            } else {
                val output = WatermarkEngine.applyWatermarks(
                    photo = photo,
                    bottomLogos = logos,
                    topLeftLogos = topLeft,
                    cornerLogo = corner,
                    bottomLogoHeightFraction = WatermarkJob.logoHeightFraction,
                    bottomMarginFraction = WatermarkJob.bottomMarginFraction,
                    bottomLeftMarginFraction = WatermarkJob.leftMarginFraction,
                    topLeftLogoHeightFraction = WatermarkJob.logoHeightFraction,
                    topLeftTopMarginFraction = WatermarkJob.topMarginFraction,
                    topLeftLeftMarginFraction = WatermarkJob.leftMarginFraction,
                    cornerLogoHeightFraction = WatermarkJob.cornerHeightFraction,
                    cornerMarginFraction = WatermarkJob.cornerMarginFraction,
                    rowLogoOpacity = WatermarkJob.rowOpacity,
                    centered = WatermarkJob.centered
                )
                val name = "watermarked_${stamp}_${index + 1}.png"
                val uri = WatermarkEngine.saveToGallery(
                    this, output, name, png = true, album = WatermarkJob.albumName
                )
                if (uri != null) saved++ else failed++
                photo.recycle()
                output.recycle()
            }
            index++
            publish(true, saved, failed, finished = false)
            updateNotification(WatermarkJob.doneCount(), WatermarkJob.total())
        }

        cache.values.forEach { it?.recycle() }
        if (saved > 0 || failed > 0) {
            HistoryStore.addRun(
                this,
                SaveRun(WatermarkJob.albumName, System.currentTimeMillis(), saved, failed)
            )
        }
        publish(false, saved, failed, finished = true)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun publish(running: Boolean, saved: Int, failed: Int, finished: Boolean) {
        WatermarkJob.progress.value = WatermarkJob.Progress(
            running = running,
            processed = WatermarkJob.doneCount(),
            total = WatermarkJob.total(),
            saved = saved,
            failed = failed,
            finished = finished
        )
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        getString(R.string.notif_channel_name),
                        NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        }
    }

    private fun buildNotification(processed: Int, total: Int): Notification {
        val text = getString(R.string.processing, processed, total)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notif_saving_title))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_save)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(total.coerceAtLeast(1), processed, total == 0)
            .build()
    }

    private fun updateNotification(processed: Int, total: Int) {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.notify(NOTIF_ID, buildNotification(processed, total))
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "watermark_saving"
        private const val NOTIF_ID = 42

        fun start(context: Context) {
            val intent = Intent(context, WatermarkService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}

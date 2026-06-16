package com.tekz.watermark

import android.app.Application
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Records uncaught crashes to a file so the next launch can show the error
 * on-screen (useful since we can't read logcat remotely).
 */
class WatermarkApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                File(filesDir, "last_crash.txt").writeText(sw.toString())
            } catch (_: Throwable) {
                // ignore
            }
            previous?.uncaughtException(thread, throwable)
        }
    }
}

package com.tekz.watermark

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** One completed save run, shown in the history list. */
data class SaveRun(
    val album: String,
    val timeMillis: Long,
    val saved: Int,
    val failed: Int
)

/**
 * Tiny persistent store (SharedPreferences + JSON) for the per-run album counter
 * and the save history.
 */
object HistoryStore {
    private const val PREFS = "watermark_history"
    private const val KEY_RUNS = "runs"
    private const val KEY_COUNTER = "album_counter"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Increments and returns the next album number (1, 2, 3 …). */
    fun nextAlbumNumber(context: Context): Int {
        val p = prefs(context)
        val n = p.getInt(KEY_COUNTER, 0) + 1
        p.edit().putInt(KEY_COUNTER, n).apply()
        return n
    }

    fun addRun(context: Context, run: SaveRun) {
        val p = prefs(context)
        val arr = JSONArray(p.getString(KEY_RUNS, "[]"))
        arr.put(
            JSONObject()
                .put("album", run.album)
                .put("time", run.timeMillis)
                .put("saved", run.saved)
                .put("failed", run.failed)
        )
        p.edit().putString(KEY_RUNS, arr.toString()).apply()
    }

    /** All runs, newest first. */
    fun getRuns(context: Context): List<SaveRun> {
        val arr = JSONArray(prefs(context).getString(KEY_RUNS, "[]"))
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            SaveRun(
                album = o.getString("album"),
                timeMillis = o.getLong("time"),
                saved = o.getInt("saved"),
                failed = o.optInt("failed", 0)
            )
        }.reversed()
    }
}

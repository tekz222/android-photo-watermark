package com.tekz.watermark

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Persists the whole working project (selected photos, logos and adjustments) so
 * it survives the app being killed in the background. Media files are referenced
 * by their internal `file://` URIs (copied into app storage when picked), so the
 * references stay readable after the process is recreated.
 */
object ProjectStore {
    private const val PREFS = "watermark_project"
    private const val KEY = "state"

    fun save(context: Context, s: WatermarkUiState, nextLogoId: Long) {
        val o = JSONObject()
        o.put("photos", JSONArray(s.photoUris.map { it.toString() }))
        o.put("bottom", logosToJson(s.logos))
        o.put("topLeft", logosToJson(s.topLeftLogos))
        o.put("corner", s.cornerLogoUri?.toString() ?: JSONObject.NULL)
        o.put("nextLogoId", nextLogoId)
        o.put("logoHeight", s.logoHeightPercent.toDouble())
        o.put("leftMargin", s.leftMarginPercent.toDouble())
        o.put("opacity", s.logoOpacityPercent.toDouble())
        o.put("bottomMargin", s.bottomMarginPercent.toDouble())
        o.put("topMargin", s.topMarginPercent.toDouble())
        o.put("cornerHeight", s.cornerLogoHeightPercent.toDouble())
        o.put("cornerMargin", s.cornerMarginPercent.toDouble())
        o.put("centered", s.centered)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, o.toString()).apply()
    }

    data class Loaded(
        val photoUris: List<Uri>,
        val logos: List<LogoItem>,
        val topLeftLogos: List<LogoItem>,
        val cornerLogoUri: Uri?,
        val nextLogoId: Long,
        val logoHeight: Float,
        val leftMargin: Float,
        val opacity: Float,
        val bottomMargin: Float,
        val topMargin: Float,
        val cornerHeight: Float,
        val cornerMargin: Float,
        val centered: Boolean
    )

    fun load(context: Context): Loaded? {
        val str = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return null
        return try {
            val o = JSONObject(str)
            val cornerStr = if (o.isNull("corner")) null else o.optString("corner", null)
            Loaded(
                photoUris = jsonToUris(o.optJSONArray("photos")).filter { exists(it) },
                logos = jsonToLogos(o.optJSONArray("bottom")).filter { exists(it.uri) },
                topLeftLogos = jsonToLogos(o.optJSONArray("topLeft")).filter { exists(it.uri) },
                cornerLogoUri = cornerStr?.let { Uri.parse(it) }?.takeIf { exists(it) },
                nextLogoId = o.optLong("nextLogoId", 0L),
                logoHeight = o.optDouble("logoHeight", 22.0).toFloat(),
                leftMargin = o.optDouble("leftMargin", 1.0).toFloat(),
                opacity = o.optDouble("opacity", 90.0).toFloat(),
                bottomMargin = o.optDouble("bottomMargin", 2.0).toFloat(),
                topMargin = o.optDouble("topMargin", 2.0).toFloat(),
                cornerHeight = o.optDouble("cornerHeight", 22.0).toFloat(),
                cornerMargin = o.optDouble("cornerMargin", 2.0).toFloat(),
                centered = o.optBoolean("centered", false)
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun logosToJson(logos: List<LogoItem>): JSONArray {
        val arr = JSONArray()
        logos.forEach {
            arr.put(
                JSONObject()
                    .put("id", it.id)
                    .put("uri", it.uri.toString())
                    .put("key", it.sourceKey)
            )
        }
        return arr
    }

    private fun jsonToUris(arr: JSONArray?): List<Uri> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).map { Uri.parse(arr.getString(it)) }
    }

    private fun jsonToLogos(arr: JSONArray?): List<LogoItem> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            LogoItem(
                id = o.getLong("id"),
                uri = Uri.parse(o.getString("uri")),
                sourceKey = o.optString("key", o.getString("uri"))
            )
        }
    }

    private fun exists(uri: Uri): Boolean =
        if (uri.scheme == "file") uri.path?.let { File(it).exists() } ?: false
        else true // bundled resource / other schemes are always available
}

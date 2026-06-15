package com.tekz.watermark

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import java.io.IOException

/**
 * Stateless image-processing helper. It loads photos and logos and draws three
 * independent groups onto each photo:
 *
 *  - a **bottom** row of logos (left-anchored, running left-to-right, touching),
 *  - a **top-left** row of logos (same layout, anchored to the top-left), and
 *  - a single **top-right** logo (the main company logo).
 *
 * The result is then written to the device gallery.
 */
object WatermarkEngine {

    /** Sub-folder created inside the public Pictures directory. */
    const val ALBUM_NAME = "Watermarked"

    /**
     * Draws the bottom row, the top-left row and an optional top-right corner
     * logo onto a copy of [photo]. The rows are laid out left-to-right with each
     * logo touching the next (no gaps); every logo keeps its own aspect ratio.
     *
     * All sizes and margins are fractions of the photo's *shortest* side so the
     * result looks consistent in both portrait and landscape.
     *
     * @return a new ARGB_8888 bitmap; [photo] is left untouched.
     */
    fun applyWatermarks(
        photo: Bitmap,
        bottomLogos: List<Bitmap> = emptyList(),
        topLeftLogos: List<Bitmap> = emptyList(),
        cornerLogo: Bitmap? = null,
        bottomLogoHeightFraction: Float = 0.12f,
        bottomMarginFraction: Float = 0.03f,
        bottomLeftMarginFraction: Float = 0.03f,
        topLeftLogoHeightFraction: Float = 0.12f,
        topLeftTopMarginFraction: Float = 0.03f,
        topLeftLeftMarginFraction: Float = 0.03f,
        cornerLogoHeightFraction: Float = 0.12f,
        cornerMarginFraction: Float = 0.04f,
        rowLogoOpacity: Float = 1f,
        centered: Boolean = false
    ): Bitmap {
        val result = photo.copy(Bitmap.Config.ARGB_8888, true)
        if (bottomLogos.isEmpty() && topLeftLogos.isEmpty() && cornerLogo == null) return result

        val canvas = Canvas(result)
        val shortestSide = minOf(result.width, result.height).toFloat()

        // Opacity applies to the bottom and top rows; the main corner logo stays opaque.
        val rowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            isFilterBitmap = true
            isDither = true
            alpha = (rowLogoOpacity.coerceIn(0f, 1f) * 255).toInt()
        }
        val cornerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            isFilterBitmap = true
            isDither = true
        }

        // ---- Top-left / top row ----
        if (topLeftLogos.isNotEmpty()) {
            val height = (shortestSide * topLeftLogoHeightFraction).coerceAtLeast(1f)
            val top = shortestSide * topLeftTopMarginFraction
            val startX = if (centered) {
                (result.width - rowWidth(topLeftLogos, height)) / 2f
            } else {
                shortestSide * topLeftLeftMarginFraction
            }
            drawRow(canvas, topLeftLogos, startX, top, height, rowPaint)
        }

        // ---- Bottom row ----
        if (bottomLogos.isNotEmpty()) {
            val height = (shortestSide * bottomLogoHeightFraction).coerceAtLeast(1f)
            val top = result.height - shortestSide * bottomMarginFraction - height
            val startX = if (centered) {
                (result.width - rowWidth(bottomLogos, height)) / 2f
            } else {
                shortestSide * bottomLeftMarginFraction
            }
            drawRow(canvas, bottomLogos, startX, top, height, rowPaint)
        }

        // ---- Top-right corner logo (main company logo) ----
        if (cornerLogo != null) {
            val height = (shortestSide * cornerLogoHeightFraction).coerceAtLeast(1f)
            val width = height * (cornerLogo.width.toFloat() / cornerLogo.height.toFloat())
            val margin = shortestSide * cornerMarginFraction
            val right = result.width - margin
            val left = right - width
            val top = margin
            val dest = RectF(left, top, right, top + height)
            val src = Rect(0, 0, cornerLogo.width, cornerLogo.height)
            canvas.drawBitmap(cornerLogo, src, dest, cornerPaint)
        }

        return result
    }

    /** Total width of [logos] laid out touching at the given [height]. */
    private fun rowWidth(logos: List<Bitmap>, height: Float): Float =
        logos.fold(0f) { acc, logo ->
            acc + height * (logo.width.toFloat() / logo.height.toFloat())
        }

    /**
     * Draws [logos] as a single horizontal row starting at [startX]/[top], each
     * logo scaled to [height] and placed immediately after the previous one.
     */
    private fun drawRow(
        canvas: Canvas,
        logos: List<Bitmap>,
        startX: Float,
        top: Float,
        height: Float,
        paint: Paint
    ) {
        var x = startX
        logos.forEach { logo ->
            val w = height * (logo.width.toFloat() / logo.height.toFloat())
            val dest = RectF(x, top, x + w, top + height)
            val src = Rect(0, 0, logo.width, logo.height)
            canvas.drawBitmap(logo, src, dest, paint)
            x += w
        }
    }

    /**
     * Loads a bitmap from [uri], honouring its EXIF orientation and optionally
     * down-sampling so the longest edge does not exceed [maxDimension] (a guard
     * against OutOfMemoryError on very large images). Returns null on failure.
     */
    fun loadBitmap(
        resolver: ContentResolver,
        uri: Uri,
        maxDimension: Int = 4096
    ): Bitmap? {
        // First pass: read bounds only.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options = BitmapFactory.Options().apply {
            inSampleSize = calculateInSampleSize(bounds.outWidth, bounds.outHeight, maxDimension)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: return null

        val orientation = readExifOrientation(resolver, uri)
        return applyExifOrientation(decoded, orientation)
    }

    private fun calculateInSampleSize(width: Int, height: Int, maxDimension: Int): Int {
        var sampleSize = 1
        var w = width
        var h = height
        while (w > maxDimension || h > maxDimension) {
            sampleSize *= 2
            w /= 2
            h /= 2
        }
        return sampleSize
    }

    private fun readExifOrientation(resolver: ContentResolver, uri: Uri): Int {
        return try {
            resolver.openInputStream(uri)?.use { input ->
                ExifInterface(input).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL
                )
            } ?: ExifInterface.ORIENTATION_NORMAL
        } catch (e: IOException) {
            ExifInterface.ORIENTATION_NORMAL
        }
    }

    private fun applyExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f); matrix.postScale(-1f, 1f)
            }
            else -> return bitmap
        }
        return try {
            val rotated = Bitmap.createBitmap(
                bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
            )
            if (rotated != bitmap) bitmap.recycle()
            rotated
        } catch (e: OutOfMemoryError) {
            bitmap
        }
    }

    /**
     * Saves [bitmap] as a JPEG into Pictures/[ALBUM_NAME] in the shared gallery.
     * Works on API 24+ : uses MediaStore's RELATIVE_PATH on API 29+, and falls
     * back to a direct public-directory insert on older versions.
     *
     * @return the content [Uri] of the saved image, or null on failure.
     */
    fun saveToGallery(
        context: Context,
        bitmap: Bitmap,
        displayName: String,
        quality: Int = 95
    ): Uri? {
        val resolver = context.contentResolver
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/$ALBUM_NAME"
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }

        val uri = resolver.insert(collection, values) ?: return null
        try {
            resolver.openOutputStream(uri)?.use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) {
                    throw IOException("Bitmap.compress returned false")
                }
            } ?: throw IOException("Could not open output stream for $uri")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            return uri
        } catch (e: Exception) {
            // Roll back the half-written entry so we don't leave an empty file behind.
            resolver.delete(uri, null, null)
            return null
        }
    }
}

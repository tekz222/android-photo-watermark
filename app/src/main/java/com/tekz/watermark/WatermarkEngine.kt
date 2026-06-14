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
 * Stateless image-processing helper. It loads photos and logos, draws the
 * bottom logos as a left-anchored row that runs left-to-right (the logos touch
 * each other) and, optionally, a single logo in the top-right corner, then
 * writes the result to the device gallery.
 */
object WatermarkEngine {

    /** Sub-folder created inside the public Pictures directory. */
    const val ALBUM_NAME = "Watermarked"

    /**
     * The bottom row begins slightly off the left edge so the first logo bleeds
     * a little past the border, as requested ("a small negative left space").
     * Expressed as a fraction of the photo's shortest side.
     */
    const val BOTTOM_LEFT_START_FRACTION = -0.02f

    /**
     * Draws [bottomLogos] and an optional [cornerLogo] onto a copy of [photo].
     *
     * The bottom logos are laid out from the left edge towards the right, each
     * logo touching the next (no gaps), starting from a small negative offset so
     * the first one bleeds past the left border. The corner logo, if present, is
     * placed in the top-right corner.
     *
     * @param bottomLogoHeightFraction height of each bottom logo relative to the
     *        photo's *shortest* side (e.g. 0.12 == 12%). All bottom logos share
     *        the same height; each keeps its own aspect ratio.
     * @param bottomPaddingFraction distance from the bottom edge, relative to the
     *        photo's shortest side.
     * @param cornerLogoHeightFraction height of the corner logo relative to the
     *        photo's shortest side.
     * @param cornerMarginFraction distance of the corner logo from the top and
     *        right edges, relative to the photo's shortest side.
     * @param opacity logo opacity in the 0f..1f range.
     * @return a new ARGB_8888 bitmap; [photo] is left untouched.
     */
    fun applyWatermarks(
        photo: Bitmap,
        bottomLogos: List<Bitmap>,
        cornerLogo: Bitmap? = null,
        bottomLogoHeightFraction: Float = 0.12f,
        bottomPaddingFraction: Float = 0f,
        cornerLogoHeightFraction: Float = 0.12f,
        cornerMarginFraction: Float = 0.04f,
        opacity: Float = 1f
    ): Bitmap {
        val result = photo.copy(Bitmap.Config.ARGB_8888, true)
        if (bottomLogos.isEmpty() && cornerLogo == null) return result

        val canvas = Canvas(result)
        val shortestSide = minOf(result.width, result.height).toFloat()

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            isFilterBitmap = true
            isDither = true
            alpha = (opacity.coerceIn(0f, 1f) * 255).toInt()
        }

        // ---- Bottom row: left-anchored, logos touching, left-to-right ----
        if (bottomLogos.isNotEmpty()) {
            val height = (shortestSide * bottomLogoHeightFraction).coerceAtLeast(1f)
            val bottomPadding = shortestSide * bottomPaddingFraction
            val top = result.height - bottomPadding - height

            var x = shortestSide * BOTTOM_LEFT_START_FRACTION
            bottomLogos.forEach { logo ->
                val w = height * (logo.width.toFloat() / logo.height.toFloat())
                val dest = RectF(x, top, x + w, top + height)
                val src = Rect(0, 0, logo.width, logo.height)
                canvas.drawBitmap(logo, src, dest, paint)
                x += w
            }
        }

        // ---- Top-right corner logo ----
        if (cornerLogo != null) {
            val height = (shortestSide * cornerLogoHeightFraction).coerceAtLeast(1f)
            val width = height * (cornerLogo.width.toFloat() / cornerLogo.height.toFloat())
            val margin = shortestSide * cornerMarginFraction
            val right = result.width - margin
            val left = right - width
            val top = margin
            val dest = RectF(left, top, right, top + height)
            val src = Rect(0, 0, cornerLogo.width, cornerLogo.height)
            canvas.drawBitmap(cornerLogo, src, dest, paint)
        }

        return result
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

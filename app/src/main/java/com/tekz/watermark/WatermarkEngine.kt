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
 * Stateless image-processing helper. It loads photos and logos, lays the logos
 * out in a single horizontal row centered along the bottom of the photo (with a
 * professional-looking margin), and writes the result to the device gallery.
 */
object WatermarkEngine {

    /** Sub-folder created inside the public Pictures directory. */
    const val ALBUM_NAME = "Watermarked"

    /**
     * Draws [logos] onto a copy of [photo] as one evenly spaced, horizontally
     * centered row near the bottom edge.
     *
     * @param logoHeightFraction height of each logo relative to the photo's
     *        *shortest* side (e.g. 0.12 == 12%). All logos share the same height
     *        so the row stays visually aligned; each keeps its own aspect ratio.
     * @param bottomPaddingFraction distance from the bottom edge, relative to the
     *        photo's shortest side.
     * @param gapFraction horizontal gap between logos, relative to the photo's
     *        shortest side.
     * @param opacity logo opacity in the 0f..1f range.
     * @return a new ARGB_8888 bitmap; [photo] is left untouched.
     */
    fun applyLogosRow(
        photo: Bitmap,
        logos: List<Bitmap>,
        logoHeightFraction: Float = 0.12f,
        bottomPaddingFraction: Float = 0.05f,
        gapFraction: Float = 0.04f,
        opacity: Float = 1f
    ): Bitmap {
        val result = photo.copy(Bitmap.Config.ARGB_8888, true)
        if (logos.isEmpty()) return result

        val canvas = Canvas(result)
        val shortestSide = minOf(result.width, result.height).toFloat()

        val targetHeight = (shortestSide * logoHeightFraction).coerceAtLeast(1f)
        val gap = shortestSide * gapFraction
        val bottomPadding = shortestSide * bottomPaddingFraction

        // Width of each logo when scaled to the common target height.
        val widths = logos.map { targetHeight * (it.width.toFloat() / it.height.toFloat()) }
        var rowWidth = widths.sum() + gap * (logos.size - 1)

        // If the row is wider than 92% of the photo, scale the whole row to fit.
        val maxWidth = result.width * 0.92f
        val fit = if (rowWidth > maxWidth) maxWidth / rowWidth else 1f
        val height = targetHeight * fit
        val scaledGap = gap * fit
        val scaledWidths = widths.map { it * fit }
        rowWidth = scaledWidths.sum() + scaledGap * (logos.size - 1)

        var x = (result.width - rowWidth) / 2f
        val top = result.height - bottomPadding - height

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            isFilterBitmap = true
            isDither = true
            alpha = (opacity.coerceIn(0f, 1f) * 255).toInt()
        }

        logos.forEachIndexed { index, logo ->
            val w = scaledWidths[index]
            val dest = RectF(x, top, x + w, top + height)
            val src = Rect(0, 0, logo.width, logo.height)
            canvas.drawBitmap(logo, src, dest, paint)
            x += w + scaledGap
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

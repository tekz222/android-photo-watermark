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

/** Which corner of the photo the logo is anchored to. */
enum class Corner {
    TOP_LEFT,
    TOP_RIGHT,
    BOTTOM_LEFT,
    BOTTOM_RIGHT
}

/**
 * Stateless image-processing helper. It loads photos and the logo, composites the
 * logo into the chosen corner with a professional-looking padding, and writes the
 * result to the device gallery.
 */
object WatermarkEngine {

    /** Sub-folder created inside the public Pictures directory. */
    const val ALBUM_NAME = "Watermarked"

    /**
     * Draws [logo] onto a copy of [photo] in the given [corner].
     *
     * @param logoWidthFraction width of the logo relative to the photo's *shortest*
     *        side (e.g. 0.18 == 18%). Using the shortest side keeps the logo a
     *        sensible size for both landscape and portrait photos.
     * @param paddingFraction distance from the photo edges, relative to the photo's
     *        shortest side (e.g. 0.04 == 4%).
     * @param opacity logo opacity in the 0f..1f range.
     * @return a new ARGB_8888 bitmap; [photo] is left untouched.
     */
    fun applyWatermark(
        photo: Bitmap,
        logo: Bitmap,
        corner: Corner,
        logoWidthFraction: Float = 0.18f,
        paddingFraction: Float = 0.04f,
        opacity: Float = 1f
    ): Bitmap {
        val result = photo.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(result)

        val shortestSide = minOf(result.width, result.height).toFloat()

        // Target logo size, preserving the logo's aspect ratio.
        val targetLogoWidth = (shortestSide * logoWidthFraction).coerceAtLeast(1f)
        val logoAspect = logo.height.toFloat() / logo.width.toFloat()
        val targetLogoHeight = targetLogoWidth * logoAspect

        val padding = shortestSide * paddingFraction

        val left: Float
        val top: Float
        when (corner) {
            Corner.TOP_LEFT -> {
                left = padding
                top = padding
            }
            Corner.TOP_RIGHT -> {
                left = result.width - targetLogoWidth - padding
                top = padding
            }
            Corner.BOTTOM_LEFT -> {
                left = padding
                top = result.height - targetLogoHeight - padding
            }
            Corner.BOTTOM_RIGHT -> {
                left = result.width - targetLogoWidth - padding
                top = result.height - targetLogoHeight - padding
            }
        }

        val dest = RectF(left, top, left + targetLogoWidth, top + targetLogoHeight)
        val src = Rect(0, 0, logo.width, logo.height)

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            isFilterBitmap = true
            isDither = true
            alpha = (opacity.coerceIn(0f, 1f) * 255).toInt()
        }
        canvas.drawBitmap(logo, src, dest, paint)
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

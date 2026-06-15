package com.tekz.watermark

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Result of the last batch run, surfaced to the UI as a one-off message. */
data class ProcessResult(
    val saved: Int,
    val failed: Int
)

/**
 * A single logo placed in a row. Each entry carries a unique [id] so the *same*
 * image can be added several times (the row simply keeps appending logos until
 * they run off the frame) while still being individually removable.
 */
data class LogoItem(
    val id: Long,
    val uri: Uri
)

data class WatermarkUiState(
    val photoUris: List<Uri> = emptyList(),
    // Bottom row of logos.
    val logos: List<LogoItem> = emptyList(),
    // Size and left margin are SHARED by the bottom and top rows.
    val logoHeightPercent: Float = 22f,
    val leftMarginPercent: Float = 2f,
    val logoOpacityPercent: Float = 100f,
    val bottomMarginPercent: Float = 1f,
    // Top-left row of logos.
    val topLeftLogos: List<LogoItem> = emptyList(),
    val topMarginPercent: Float = 1f,
    // Layout of each row: false = left-to-right (anchored left), true = centered.
    val centered: Boolean = false,
    // Single top-right main company logo.
    val cornerLogoUri: Uri? = null,
    val cornerLogoHeightPercent: Float = 12f,
    val cornerMarginPercent: Float = 4f,
    val isProcessing: Boolean = false,
    val processed: Int = 0,
    val total: Int = 0,
    val lastResult: ProcessResult? = null,
    /** One-off message (string resource id) to surface as a snackbar. */
    val messageRes: Int? = null
) {
    val hasAnyLogo: Boolean
        get() = logos.isNotEmpty() || topLeftLogos.isNotEmpty() || cornerLogoUri != null

    val canProcess: Boolean
        get() = !isProcessing && photoUris.isNotEmpty() && hasAnyLogo
}

class WatermarkViewModel(app: Application) : AndroidViewModel(app) {

    private val _uiState = MutableStateFlow(WatermarkUiState())
    val uiState: StateFlow<WatermarkUiState> = _uiState.asStateFlow()

    /** Monotonic id source so every appended logo entry is unique. */
    private var nextLogoId = 0L
    private fun newLogoItems(uris: List<Uri>): List<LogoItem> =
        uris.map { LogoItem(id = nextLogoId++, uri = it) }

    /** Adds newly picked photos, ignoring duplicates already present. */
    fun addPhotos(uris: List<Uri>) = _uiState.update {
        it.copy(photoUris = (it.photoUris + uris).distinct(), lastResult = null)
    }

    fun removePhoto(uri: Uri) = _uiState.update {
        it.copy(photoUris = it.photoUris.filterNot { u -> u == uri }, lastResult = null)
    }

    /** Appends newly picked bottom logos (duplicates allowed within the row), but
     * skips any logo already used in the top row. */
    fun addLogos(uris: List<Uri>) = _uiState.update {
        val inTop = it.topLeftLogos.mapTo(HashSet()) { item -> item.uri }
        val allowed = uris.filterNot { u -> u in inTop }
        it.copy(
            logos = it.logos + newLogoItems(allowed),
            messageRes = if (allowed.size < uris.size) R.string.dup_in_top else null,
            lastResult = null
        )
    }

    fun removeLogo(id: Long) = _uiState.update {
        it.copy(logos = it.logos.filterNot { item -> item.id == id }, lastResult = null)
    }

    /** Appends newly picked top-left logos, but skips any logo already used in the
     * bottom row. */
    fun addTopLeftLogos(uris: List<Uri>) = _uiState.update {
        val inBottom = it.logos.mapTo(HashSet()) { item -> item.uri }
        val allowed = uris.filterNot { u -> u in inBottom }
        it.copy(
            topLeftLogos = it.topLeftLogos + newLogoItems(allowed),
            messageRes = if (allowed.size < uris.size) R.string.dup_in_bottom else null,
            lastResult = null
        )
    }

    fun removeTopLeftLogo(id: Long) = _uiState.update {
        it.copy(topLeftLogos = it.topLeftLogos.filterNot { item -> item.id == id }, lastResult = null)
    }

    /** Reorders the bottom row by moving the logo at [from] to index [to]. */
    fun moveLogo(from: Int, to: Int) = _uiState.update {
        it.copy(logos = it.logos.moveItem(from, to), lastResult = null)
    }

    /** Reorders the top-left row by moving the logo at [from] to index [to]. */
    fun moveTopLeftLogo(from: Int, to: Int) = _uiState.update {
        it.copy(topLeftLogos = it.topLeftLogos.moveItem(from, to), lastResult = null)
    }

    private fun <T> List<T>.moveItem(from: Int, to: Int): List<T> {
        if (from == to || from !in indices || to !in indices) return this
        return toMutableList().apply { add(to, removeAt(from)) }
    }

    /** Sets (or replaces) the single top-right main company logo. */
    fun setCornerLogo(uri: Uri?) = _uiState.update {
        it.copy(cornerLogoUri = uri, lastResult = null)
    }

    // Shared by both rows.
    fun setLogoHeightPercent(value: Float) = _uiState.update { it.copy(logoHeightPercent = value) }

    fun setLeftMarginPercent(value: Float) =
        _uiState.update { it.copy(leftMarginPercent = value) }

    fun setLogoOpacityPercent(value: Float) =
        _uiState.update { it.copy(logoOpacityPercent = value) }

    fun setCentered(value: Boolean) = _uiState.update { it.copy(centered = value) }

    // Row-specific edge distances.
    fun setBottomMarginPercent(value: Float) =
        _uiState.update { it.copy(bottomMarginPercent = value) }

    fun setTopMarginPercent(value: Float) =
        _uiState.update { it.copy(topMarginPercent = value) }

    // Top-right main logo adjustments.
    fun setCornerLogoHeightPercent(value: Float) =
        _uiState.update { it.copy(cornerLogoHeightPercent = value) }

    fun setCornerMarginPercent(value: Float) =
        _uiState.update { it.copy(cornerMarginPercent = value) }

    fun clearResult() {
        _uiState.update { it.copy(lastResult = null) }
    }

    fun clearMessage() {
        _uiState.update { it.copy(messageRes = null) }
    }

    /**
     * Processes every photo: loads it, draws the row of logos centered along the
     * bottom and saves the result to the gallery. Runs off the main thread and
     * publishes progress as it goes.
     */
    fun processAll() {
        val state = _uiState.value
        if (state.isProcessing) return
        if (state.photoUris.isEmpty()) return
        if (!state.hasAnyLogo) return

        viewModelScope.launch {
            _uiState.update {
                it.copy(
                    isProcessing = true,
                    processed = 0,
                    total = state.photoUris.size,
                    lastResult = null
                )
            }

            val result = withContext(Dispatchers.Default) {
                val context = getApplication<Application>()
                val resolver = context.contentResolver

                // Decode each distinct logo uri once, even when it repeats in a row.
                val logoCache = HashMap<Uri, android.graphics.Bitmap?>()
                fun bitmapFor(uri: Uri) =
                    logoCache.getOrPut(uri) { WatermarkEngine.loadBitmap(resolver, uri) }

                val logos = state.logos.mapNotNull { bitmapFor(it.uri) }
                val topLeftLogos = state.topLeftLogos.mapNotNull { bitmapFor(it.uri) }
                val cornerLogo = state.cornerLogoUri?.let { bitmapFor(it) }
                if (logos.isEmpty() && topLeftLogos.isEmpty() && cornerLogo == null) {
                    return@withContext ProcessResult(saved = 0, failed = state.photoUris.size)
                }

                val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                var saved = 0
                var failed = 0

                state.photoUris.forEachIndexed { index, photoUri ->
                    val photo = WatermarkEngine.loadBitmap(resolver, photoUri)
                    if (photo == null) {
                        failed++
                    } else {
                        val output = WatermarkEngine.applyWatermarks(
                            photo = photo,
                            bottomLogos = logos,
                            topLeftLogos = topLeftLogos,
                            cornerLogo = cornerLogo,
                            bottomLogoHeightFraction = state.logoHeightPercent / 100f,
                            bottomMarginFraction = state.bottomMarginPercent / 100f,
                            bottomLeftMarginFraction = state.leftMarginPercent / 100f,
                            topLeftLogoHeightFraction = state.logoHeightPercent / 100f,
                            topLeftTopMarginFraction = state.topMarginPercent / 100f,
                            topLeftLeftMarginFraction = state.leftMarginPercent / 100f,
                            cornerLogoHeightFraction = state.cornerLogoHeightPercent / 100f,
                            cornerMarginFraction = state.cornerMarginPercent / 100f,
                            rowLogoOpacity = state.logoOpacityPercent / 100f,
                            centered = state.centered
                        )
                        val name = "watermarked_${stamp}_${index + 1}.jpg"
                        val uri = WatermarkEngine.saveToGallery(context, output, name)
                        if (uri != null) saved++ else failed++

                        photo.recycle()
                        output.recycle()
                    }
                    _uiState.update { it.copy(processed = index + 1) }
                }

                // Each distinct bitmap was cached, so recycle them once here.
                logoCache.values.forEach { it?.recycle() }
                ProcessResult(saved = saved, failed = failed)
            }

            _uiState.update { it.copy(isProcessing = false, lastResult = result) }
        }
    }
}

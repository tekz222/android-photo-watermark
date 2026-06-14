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

data class WatermarkUiState(
    val photoUris: List<Uri> = emptyList(),
    val logoUris: List<Uri> = emptyList(),
    val cornerLogoUri: Uri? = null,
    val logoHeightPercent: Float = 12f,
    val bottomPaddingPercent: Float = 0f,
    val cornerLogoHeightPercent: Float = 12f,
    val cornerMarginPercent: Float = 4f,
    val isProcessing: Boolean = false,
    val processed: Int = 0,
    val total: Int = 0,
    val lastResult: ProcessResult? = null
) {
    val canProcess: Boolean
        get() = !isProcessing && photoUris.isNotEmpty() &&
            (logoUris.isNotEmpty() || cornerLogoUri != null)
}

class WatermarkViewModel(app: Application) : AndroidViewModel(app) {

    private val _uiState = MutableStateFlow(WatermarkUiState())
    val uiState: StateFlow<WatermarkUiState> = _uiState.asStateFlow()

    /** Adds newly picked photos, ignoring duplicates already present. */
    fun addPhotos(uris: List<Uri>) = _uiState.update {
        it.copy(photoUris = (it.photoUris + uris).distinct(), lastResult = null)
    }

    fun removePhoto(uri: Uri) = _uiState.update {
        it.copy(photoUris = it.photoUris.filterNot { u -> u == uri }, lastResult = null)
    }

    /** Adds newly picked logos, ignoring duplicates already present. */
    fun addLogos(uris: List<Uri>) = _uiState.update {
        it.copy(logoUris = (it.logoUris + uris).distinct(), lastResult = null)
    }

    fun removeLogo(uri: Uri) = _uiState.update {
        it.copy(logoUris = it.logoUris.filterNot { u -> u == uri }, lastResult = null)
    }

    /** Sets (or replaces) the single top-right corner logo. */
    fun setCornerLogo(uri: Uri?) = _uiState.update {
        it.copy(cornerLogoUri = uri, lastResult = null)
    }

    fun setLogoHeightPercent(value: Float) = _uiState.update { it.copy(logoHeightPercent = value) }

    fun setBottomPaddingPercent(value: Float) =
        _uiState.update { it.copy(bottomPaddingPercent = value) }

    fun setCornerLogoHeightPercent(value: Float) =
        _uiState.update { it.copy(cornerLogoHeightPercent = value) }

    fun setCornerMarginPercent(value: Float) =
        _uiState.update { it.copy(cornerMarginPercent = value) }

    fun clearResult() {
        _uiState.update { it.copy(lastResult = null) }
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
        if (state.logoUris.isEmpty() && state.cornerLogoUri == null) return

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

                val logos = state.logoUris.mapNotNull { WatermarkEngine.loadBitmap(resolver, it) }
                val cornerLogo = state.cornerLogoUri?.let { WatermarkEngine.loadBitmap(resolver, it) }
                if (logos.isEmpty() && cornerLogo == null) {
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
                            cornerLogo = cornerLogo,
                            bottomLogoHeightFraction = state.logoHeightPercent / 100f,
                            bottomPaddingFraction = state.bottomPaddingPercent / 100f,
                            cornerLogoHeightFraction = state.cornerLogoHeightPercent / 100f,
                            cornerMarginFraction = state.cornerMarginPercent / 100f
                        )
                        val name = "watermarked_${stamp}_${index + 1}.jpg"
                        val uri = WatermarkEngine.saveToGallery(context, output, name)
                        if (uri != null) saved++ else failed++

                        photo.recycle()
                        output.recycle()
                    }
                    _uiState.update { it.copy(processed = index + 1) }
                }

                logos.forEach { it.recycle() }
                cornerLogo?.recycle()
                ProcessResult(saved = saved, failed = failed)
            }

            _uiState.update { it.copy(isProcessing = false, lastResult = result) }
        }
    }
}

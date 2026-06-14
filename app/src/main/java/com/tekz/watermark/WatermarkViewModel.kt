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
    val logoUri: Uri? = null,
    val corner: Corner = Corner.BOTTOM_RIGHT,
    val logoWidthPercent: Float = 18f,
    val paddingPercent: Float = 4f,
    val isProcessing: Boolean = false,
    val processed: Int = 0,
    val total: Int = 0,
    val lastResult: ProcessResult? = null
) {
    val canProcess: Boolean
        get() = photoUris.isNotEmpty() && logoUri != null && !isProcessing
}

class WatermarkViewModel(app: Application) : AndroidViewModel(app) {

    private val _uiState = MutableStateFlow(WatermarkUiState())
    val uiState: StateFlow<WatermarkUiState> = _uiState.asStateFlow()

    fun setPhotos(uris: List<Uri>) {
        _uiState.update { it.copy(photoUris = uris, lastResult = null) }
    }

    fun setLogo(uri: Uri?) {
        _uiState.update { it.copy(logoUri = uri, lastResult = null) }
    }

    fun setCorner(corner: Corner) {
        _uiState.update { it.copy(corner = corner) }
    }

    fun setLogoWidthPercent(value: Float) {
        _uiState.update { it.copy(logoWidthPercent = value) }
    }

    fun setPaddingPercent(value: Float) {
        _uiState.update { it.copy(paddingPercent = value) }
    }

    fun clearResult() {
        _uiState.update { it.copy(lastResult = null) }
    }

    /**
     * Processes every selected photo: loads it, draws the logo in the chosen
     * corner and saves the result to the gallery. Runs off the main thread and
     * publishes progress as it goes.
     */
    fun processAll() {
        val state = _uiState.value
        val logoUri = state.logoUri ?: return
        if (state.photoUris.isEmpty() || state.isProcessing) return

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

                val logo = WatermarkEngine.loadBitmap(resolver, logoUri)
                    ?: return@withContext ProcessResult(saved = 0, failed = state.photoUris.size)

                val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                var saved = 0
                var failed = 0

                state.photoUris.forEachIndexed { index, photoUri ->
                    val photo = WatermarkEngine.loadBitmap(resolver, photoUri)
                    if (photo == null) {
                        failed++
                    } else {
                        val output = WatermarkEngine.applyWatermark(
                            photo = photo,
                            logo = logo,
                            corner = state.corner,
                            logoWidthFraction = state.logoWidthPercent / 100f,
                            paddingFraction = state.paddingPercent / 100f
                        )
                        val name = "watermarked_${stamp}_${index + 1}.jpg"
                        val uri = WatermarkEngine.saveToGallery(context, output, name)
                        if (uri != null) saved++ else failed++

                        photo.recycle()
                        output.recycle()
                    }
                    _uiState.update { it.copy(processed = index + 1) }
                }

                logo.recycle()
                ProcessResult(saved = saved, failed = failed)
            }

            _uiState.update {
                it.copy(isProcessing = false, lastResult = result)
            }
        }
    }
}

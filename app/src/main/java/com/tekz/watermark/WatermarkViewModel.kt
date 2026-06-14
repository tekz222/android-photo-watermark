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
 * A single "batch": its own set of photos, its own logo and its own placement
 * settings. Every group is processed independently so each photo gets the logo
 * of the group it belongs to.
 */
data class WatermarkGroup(
    val id: Long,
    val photoUris: List<Uri> = emptyList(),
    val logoUri: Uri? = null,
    val corner: Corner = Corner.BOTTOM_RIGHT,
    val logoWidthPercent: Float = 18f,
    val paddingPercent: Float = 4f
) {
    /** A group can be processed only when it has both photos and a logo. */
    val isComplete: Boolean
        get() = photoUris.isNotEmpty() && logoUri != null
}

data class WatermarkUiState(
    val groups: List<WatermarkGroup> = listOf(WatermarkGroup(id = 1L)),
    val isProcessing: Boolean = false,
    val processed: Int = 0,
    val total: Int = 0,
    val lastResult: ProcessResult? = null
) {
    val canProcess: Boolean
        get() = !isProcessing && groups.any { it.isComplete }
}

class WatermarkViewModel(app: Application) : AndroidViewModel(app) {

    private val _uiState = MutableStateFlow(WatermarkUiState())
    val uiState: StateFlow<WatermarkUiState> = _uiState.asStateFlow()

    /** Monotonic id source so each group keeps a stable identity in the UI. */
    private var nextId = 2L

    private fun updateGroup(id: Long, transform: (WatermarkGroup) -> WatermarkGroup) {
        _uiState.update { state ->
            state.copy(
                groups = state.groups.map { if (it.id == id) transform(it) else it },
                lastResult = null
            )
        }
    }

    fun addGroup() {
        _uiState.update {
            it.copy(groups = it.groups + WatermarkGroup(id = nextId++), lastResult = null)
        }
    }

    fun removeGroup(id: Long) {
        _uiState.update { state ->
            val remaining = state.groups.filterNot { it.id == id }
            // Always keep at least one group on screen.
            state.copy(
                groups = remaining.ifEmpty { listOf(WatermarkGroup(id = nextId++)) },
                lastResult = null
            )
        }
    }

    /** Adds newly picked photos to the group, ignoring duplicates already present. */
    fun addPhotos(id: Long, uris: List<Uri>) = updateGroup(id) { group ->
        group.copy(photoUris = (group.photoUris + uris).distinct())
    }

    fun removePhoto(id: Long, uri: Uri) = updateGroup(id) { group ->
        group.copy(photoUris = group.photoUris.filterNot { it == uri })
    }

    fun setLogo(id: Long, uri: Uri?) = updateGroup(id) { it.copy(logoUri = uri) }

    fun setCorner(id: Long, corner: Corner) = updateGroup(id) { it.copy(corner = corner) }

    fun setLogoWidthPercent(id: Long, value: Float) =
        updateGroup(id) { it.copy(logoWidthPercent = value) }

    fun setPaddingPercent(id: Long, value: Float) =
        updateGroup(id) { it.copy(paddingPercent = value) }

    fun clearResult() {
        _uiState.update { it.copy(lastResult = null) }
    }

    /**
     * Processes every complete group: for each photo it draws that group's logo in
     * the chosen corner and saves the result to the gallery. Runs off the main
     * thread and publishes progress across all groups combined.
     */
    fun processAll() {
        val state = _uiState.value
        if (state.isProcessing) return
        val groups = state.groups.filter { it.isComplete }
        if (groups.isEmpty()) return
        val totalPhotos = groups.sumOf { it.photoUris.size }

        viewModelScope.launch {
            _uiState.update {
                it.copy(isProcessing = true, processed = 0, total = totalPhotos, lastResult = null)
            }

            val result = withContext(Dispatchers.Default) {
                val context = getApplication<Application>()
                val resolver = context.contentResolver
                val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())

                var saved = 0
                var failed = 0
                var done = 0

                groups.forEachIndexed { groupIndex, group ->
                    val logo = WatermarkEngine.loadBitmap(resolver, group.logoUri!!)
                    if (logo == null) {
                        // Couldn't load this group's logo; count its photos as failed.
                        failed += group.photoUris.size
                        done += group.photoUris.size
                        _uiState.update { it.copy(processed = done) }
                        return@forEachIndexed
                    }

                    group.photoUris.forEachIndexed { photoIndex, photoUri ->
                        val photo = WatermarkEngine.loadBitmap(resolver, photoUri)
                        if (photo == null) {
                            failed++
                        } else {
                            val output = WatermarkEngine.applyWatermark(
                                photo = photo,
                                logo = logo,
                                corner = group.corner,
                                logoWidthFraction = group.logoWidthPercent / 100f,
                                paddingFraction = group.paddingPercent / 100f
                            )
                            val name = "watermarked_${stamp}_g${groupIndex + 1}_${photoIndex + 1}.jpg"
                            val uri = WatermarkEngine.saveToGallery(context, output, name)
                            if (uri != null) saved++ else failed++

                            photo.recycle()
                            output.recycle()
                        }
                        done++
                        _uiState.update { it.copy(processed = done) }
                    }

                    logo.recycle()
                }

                ProcessResult(saved = saved, failed = failed)
            }

            _uiState.update { it.copy(isProcessing = false, lastResult = result) }
        }
    }
}

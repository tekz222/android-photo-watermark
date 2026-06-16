package com.tekz.watermark

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Result of the last batch run, surfaced to the UI as a persistent banner. */
data class ProcessResult(
    val saved: Int,
    val failed: Int,
    val album: String
)

/**
 * A single logo placed in a row. [uri] points to an internal copy of the image
 * (so it survives process death); [sourceKey] is the original picked uri, used to
 * keep the same logo out of both rows.
 */
data class LogoItem(
    val id: Long,
    val uri: Uri,
    val sourceKey: String
)

data class WatermarkUiState(
    val photoUris: List<Uri> = emptyList(),
    // Bottom row of logos.
    val logos: List<LogoItem> = emptyList(),
    // Size and left margin are SHARED by the bottom and top rows.
    val logoHeightPercent: Float = 22f,
    val leftMarginPercent: Float = 1f,
    val logoOpacityPercent: Float = 90f,
    val bottomMarginPercent: Float = 2f,
    // Top-left row of logos.
    val topLeftLogos: List<LogoItem> = emptyList(),
    val topMarginPercent: Float = 2f,
    // Layout of each row: false = left-to-right (anchored left), true = centered.
    val centered: Boolean = false,
    // Single top-right main company logo.
    val cornerLogoUri: Uri? = null,
    val cornerLogoHeightPercent: Float = 22f,
    val cornerMarginPercent: Float = 2f,
    val isImporting: Boolean = false,
    val isProcessing: Boolean = false,
    val processed: Int = 0,
    val total: Int = 0,
    val lastResult: ProcessResult? = null,
    /** One-off message (string resource id) to surface as a snackbar. */
    val messageRes: Int? = null,
    /** Photos already saved in the current project (by internal uri). The save
     * button only ever processes photos NOT in this set, so re-pressing it after
     * adding more photos saves just the new ones — into [currentAlbum]. */
    val savedPhotoUris: Set<Uri> = emptySet(),
    /** Album (gallery folder) the current project saves into. Set on the first
     * save; reused for later additions so they land in the same place. */
    val currentAlbum: String? = null
) {
    val hasAnyLogo: Boolean
        get() = logos.isNotEmpty() || topLeftLogos.isNotEmpty() || cornerLogoUri != null

    /** Photos selected but not yet saved in this project. */
    val unsavedPhotos: List<Uri>
        get() = photoUris.filterNot { it in savedPhotoUris }

    val canProcess: Boolean
        get() = !isProcessing && hasAnyLogo && unsavedPhotos.isNotEmpty()

    /** Everything currently selected has already been saved. */
    val allSaved: Boolean
        get() = photoUris.isNotEmpty() && hasAnyLogo && unsavedPhotos.isEmpty()
}

class WatermarkViewModel(app: Application) : AndroidViewModel(app) {

    private val _uiState = MutableStateFlow(WatermarkUiState())
    val uiState: StateFlow<WatermarkUiState> = _uiState.asStateFlow()

    /** Monotonic id source so every appended logo entry is unique. */
    private var nextLogoId = 0L

    private val appCtx get() = getApplication<Application>()

    init {
        // Restore the saved project (survives the app being killed).
        val saved = ProjectStore.load(appCtx)
        if (saved != null) {
            nextLogoId = saved.nextLogoId
            _uiState.update {
                it.copy(
                    photoUris = saved.photoUris,
                    logos = saved.logos,
                    topLeftLogos = saved.topLeftLogos,
                    cornerLogoUri = saved.cornerLogoUri,
                    logoHeightPercent = saved.logoHeight,
                    leftMarginPercent = saved.leftMargin,
                    logoOpacityPercent = saved.opacity,
                    bottomMarginPercent = saved.bottomMargin,
                    topMarginPercent = saved.topMargin,
                    cornerLogoHeightPercent = saved.cornerHeight,
                    cornerMarginPercent = saved.cornerMargin,
                    centered = saved.centered,
                    // Keep only saved markers for photos that still exist.
                    savedPhotoUris = saved.savedPhotoUris.intersect(saved.photoUris.toSet()),
                    currentAlbum = saved.currentAlbum
                )
            }
        } else {
            // Fresh start: install the bundled default main logo.
            installDefaultCornerLogo()
        }

        // Mirror the background service's progress into the UI state.
        viewModelScope.launch {
            WatermarkJob.progress.collect { p ->
                var finishedNow = false
                _uiState.update { s ->
                    when {
                        p.finished && s.isProcessing -> {
                            finishedNow = true
                            // On a fully successful run, every selected photo (including
                            // any added mid-save) is now saved into the current album.
                            val nowSaved = if (p.failed == 0) s.photoUris.toSet() else s.savedPhotoUris
                            s.copy(
                                isProcessing = false,
                                processed = p.processed,
                                total = p.total,
                                lastResult = ProcessResult(
                                    saved = p.saved,
                                    failed = p.failed,
                                    album = s.currentAlbum.orEmpty()
                                ),
                                savedPhotoUris = nowSaved
                            )
                        }
                        !p.finished -> s.copy(
                            isProcessing = p.running,
                            processed = p.processed,
                            total = p.total
                        )
                        else -> s
                    }
                }
                // Persist the new saved-markers / album so they survive a kill.
                if (finishedNow) persist()
            }
        }
    }

    private fun persist() = ProjectStore.save(appCtx, _uiState.value, nextLogoId)

    /** Resets everything to a fresh project: wipes selected photos, logos and the
     * saved-state, then reinstalls the default main logo. Photos already written
     * to the gallery are NOT touched. */
    fun newProject() {
        if (_uiState.value.isProcessing) return
        ProjectStore.clear(appCtx)
        nextLogoId = 0L
        _uiState.value = WatermarkUiState()
        installDefaultCornerLogo()
    }

    /** Copies a picked image into the app's internal storage so we keep access to
     * it after the process is recreated. Returns the internal `file://` uri. */
    private fun copyToInternal(src: Uri, subdir: String): Uri? {
        return try {
            val dir = java.io.File(appCtx.filesDir, subdir).apply { mkdirs() }
            val file = java.io.File(dir, java.util.UUID.randomUUID().toString())
            val stream = appCtx.contentResolver.openInputStream(src) ?: return null
            stream.use { input -> file.outputStream().use { out -> input.copyTo(out) } }
            Uri.fromFile(file)
        } catch (e: Exception) {
            null
        }
    }

    /** Copies the bundled default logo (from assets, untouched) into internal
     * storage and sets it as the main logo. Runs once on a fresh project. */
    private fun installDefaultCornerLogo() {
        viewModelScope.launch {
            val uri = withContext(Dispatchers.IO) {
                try {
                    val dir = java.io.File(appCtx.filesDir, "logos").apply { mkdirs() }
                    val file = java.io.File(dir, "default_corner_logo.png")
                    appCtx.assets.open("default_corner_logo.png").use { input ->
                        file.outputStream().use { out -> input.copyTo(out) }
                    }
                    Uri.fromFile(file)
                } catch (e: Exception) {
                    null
                }
            }
            if (uri != null) {
                _uiState.update { it.copy(cornerLogoUri = uri) }
                persist()
            }
        }
    }

    private fun deleteInternal(uri: Uri) {
        if (uri.scheme == "file") uri.path?.let { runCatching { java.io.File(it).delete() } }
    }

    /** Copies newly picked photos into internal storage, then adds them. When a
     * save is running, the new photos are queued into the background job too. */
    fun addPhotos(uris: List<Uri>) {
        viewModelScope.launch {
            _uiState.update { it.copy(isImporting = true, lastResult = null) }
            // Copy in parallel so importing many photos is fast.
            val copied = withContext(Dispatchers.IO) {
                coroutineScope { uris.map { async { copyToInternal(it, "photos") } }.awaitAll() }
                    .filterNotNull()
            }
            _uiState.update { it.copy(photoUris = it.photoUris + copied, isImporting = false) }
            persist()
            if (_uiState.value.isProcessing) WatermarkJob.addPhotos(copied)
        }
    }

    fun removePhoto(uri: Uri) {
        _uiState.update {
            it.copy(
                photoUris = it.photoUris.filterNot { u -> u == uri },
                savedPhotoUris = it.savedPhotoUris - uri,
                lastResult = null
            )
        }
        deleteInternal(uri)
        persist()
    }

    /** Appends newly picked bottom logos (copied internally), skipping any logo
     * already used in the top row. */
    fun addLogos(uris: List<Uri>) = addLogosTo(bottom = true, uris = uris)

    /** Appends newly picked top-left logos, skipping any already in the bottom row. */
    fun addTopLeftLogos(uris: List<Uri>) = addLogosTo(bottom = false, uris = uris)

    private fun addLogosTo(bottom: Boolean, uris: List<Uri>) {
        viewModelScope.launch {
            _uiState.update { it.copy(isImporting = true, lastResult = null) }
            val state = _uiState.value
            val otherKeys = (if (bottom) state.topLeftLogos else state.logos)
                .mapTo(HashSet()) { it.sourceKey }
            var skipped = 0
            val items = withContext(Dispatchers.IO) {
                uris.mapNotNull { src ->
                    val key = src.toString()
                    if (key in otherKeys) {
                        skipped++
                        return@mapNotNull null
                    }
                    val internal = copyToInternal(src, "logos") ?: return@mapNotNull null
                    LogoItem(id = nextLogoId++, uri = internal, sourceKey = key)
                }
            }
            _uiState.update {
                if (bottom) {
                    it.copy(
                        logos = it.logos + items,
                        isImporting = false,
                        messageRes = if (skipped > 0) R.string.dup_in_top else null
                    )
                } else {
                    it.copy(
                        topLeftLogos = it.topLeftLogos + items,
                        isImporting = false,
                        messageRes = if (skipped > 0) R.string.dup_in_bottom else null
                    )
                }
            }
            persist()
        }
    }

    fun removeLogo(id: Long) {
        _uiState.value.logos.firstOrNull { it.id == id }?.let { deleteInternal(it.uri) }
        _uiState.update { it.copy(logos = it.logos.filterNot { item -> item.id == id }, lastResult = null) }
        persist()
    }

    fun removeTopLeftLogo(id: Long) {
        _uiState.value.topLeftLogos.firstOrNull { it.id == id }?.let { deleteInternal(it.uri) }
        _uiState.update { it.copy(topLeftLogos = it.topLeftLogos.filterNot { item -> item.id == id }, lastResult = null) }
        persist()
    }

    /** Reorders the bottom row by moving the logo at [from] to index [to]. */
    fun moveLogo(from: Int, to: Int) {
        _uiState.update { it.copy(logos = it.logos.moveItem(from, to), lastResult = null) }
        persist()
    }

    /** Reorders the top-left row by moving the logo at [from] to index [to]. */
    fun moveTopLeftLogo(from: Int, to: Int) {
        _uiState.update { it.copy(topLeftLogos = it.topLeftLogos.moveItem(from, to), lastResult = null) }
        persist()
    }

    private fun <T> List<T>.moveItem(from: Int, to: Int): List<T> {
        if (from == to || from !in indices || to !in indices) return this
        return toMutableList().apply { add(to, removeAt(from)) }
    }

    /** Sets (or replaces) the single top-right main company logo. */
    fun setCornerLogo(uri: Uri?) {
        if (uri == null) {
            _uiState.value.cornerLogoUri?.let { deleteInternal(it) }
            _uiState.update { it.copy(cornerLogoUri = null, lastResult = null) }
            persist()
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isImporting = true, lastResult = null) }
            val internal = withContext(Dispatchers.IO) { copyToInternal(uri, "logos") }
            _uiState.update {
                if (internal != null) it.copy(cornerLogoUri = internal, isImporting = false)
                else it.copy(isImporting = false)
            }
            persist()
        }
    }

    // Shared by both rows.
    fun setLogoHeightPercent(value: Float) { _uiState.update { it.copy(logoHeightPercent = value) }; persist() }

    fun setLeftMarginPercent(value: Float) { _uiState.update { it.copy(leftMarginPercent = value) }; persist() }

    fun setLogoOpacityPercent(value: Float) { _uiState.update { it.copy(logoOpacityPercent = value) }; persist() }

    fun setCentered(value: Boolean) { _uiState.update { it.copy(centered = value) }; persist() }

    // Row-specific edge distances.
    fun setBottomMarginPercent(value: Float) { _uiState.update { it.copy(bottomMarginPercent = value) }; persist() }

    fun setTopMarginPercent(value: Float) { _uiState.update { it.copy(topMarginPercent = value) }; persist() }

    // Top-right main logo adjustments.
    fun setCornerLogoHeightPercent(value: Float) { _uiState.update { it.copy(cornerLogoHeightPercent = value) }; persist() }

    fun setCornerMarginPercent(value: Float) { _uiState.update { it.copy(cornerMarginPercent = value) }; persist() }

    fun clearResult() {
        _uiState.update { it.copy(lastResult = null) }
    }

    fun clearMessage() {
        _uiState.update { it.copy(messageRes = null) }
    }

    /** Past save runs, newest first (album, time, counts). */
    fun history(): List<SaveRun> = HistoryStore.getRuns(getApplication())

    /**
     * Starts the background [WatermarkService] which applies the logos to every
     * photo and saves them. Each run goes into its own album ("Watermarked N").
     * The service keeps running even if the app is backgrounded; progress is
     * mirrored back into [uiState] via [WatermarkJob.progress].
     */
    fun processAll() {
        val state = _uiState.value
        if (state.isProcessing) return
        if (!state.hasAnyLogo) return
        // Only the photos not yet saved in this project get processed.
        val toSave = state.unsavedPhotos
        if (toSave.isEmpty()) return

        val context = getApplication<Application>()
        // Reuse the project's album so later additions land in the same folder;
        // on the first save, create one named by date/time (colon-free).
        val album = state.currentAlbum
            ?: SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.getDefault()).format(Date())

        WatermarkJob.bottomLogoUris = state.logos.map { it.uri }
        WatermarkJob.topLeftLogoUris = state.topLeftLogos.map { it.uri }
        WatermarkJob.cornerLogoUri = state.cornerLogoUri
        WatermarkJob.logoHeightFraction = state.logoHeightPercent / 100f
        WatermarkJob.leftMarginFraction = state.leftMarginPercent / 100f
        WatermarkJob.rowOpacity = state.logoOpacityPercent / 100f
        WatermarkJob.bottomMarginFraction = state.bottomMarginPercent / 100f
        WatermarkJob.topMarginFraction = state.topMarginPercent / 100f
        WatermarkJob.cornerHeightFraction = state.cornerLogoHeightPercent / 100f
        WatermarkJob.cornerMarginFraction = state.cornerMarginPercent / 100f
        WatermarkJob.centered = state.centered
        WatermarkJob.albumName = album
        WatermarkJob.reset(toSave)
        WatermarkJob.progress.value = WatermarkJob.Progress(
            running = true, processed = 0, total = toSave.size
        )

        _uiState.update {
            it.copy(
                isProcessing = true,
                processed = 0,
                total = toSave.size,
                lastResult = null,
                currentAlbum = album
            )
        }
        persist()
        WatermarkService.start(context)
    }
}

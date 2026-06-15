package com.tekz.watermark

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.tekz.watermark.ui.theme.PhotoWatermarkTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** How many of the selected photos to show in the live preview. */
private const val MAX_PREVIEW = 5

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            PhotoWatermarkTheme {
                WatermarkScreen()
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WatermarkScreen(viewModel: WatermarkViewModel = viewModel()) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }

    // Whether the user is allowed to write to storage (only matters on API <= 28).
    var hasLegacyWritePermission by remember {
        mutableStateOf(
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
                ContextCompat.checkSelfPermission(
                    context, Manifest.permission.WRITE_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED
        )
    }

    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris -> if (uris.isNotEmpty()) viewModel.addPhotos(uris) }

    val logoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris -> if (uris.isNotEmpty()) viewModel.addLogos(uris) }

    val topLeftLogoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris -> if (uris.isNotEmpty()) viewModel.addTopLeftLogos(uris) }

    val cornerLogoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> if (uri != null) viewModel.setCornerLogo(uri) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasLegacyWritePermission = granted
        if (granted) viewModel.processAll()
    }

    fun startProcessing() {
        if (hasLegacyWritePermission) {
            viewModel.processAll()
        } else {
            permissionLauncher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }
    }

    // Surface the result of the last batch run as a snackbar.
    LaunchedEffect(state.lastResult) {
        val result = state.lastResult ?: return@LaunchedEffect
        val message = if (result.failed == 0) {
            context.getString(R.string.result_success, result.saved)
        } else {
            context.getString(R.string.result_partial, result.saved, result.failed)
        }
        snackbarHostState.showSnackbar(message)
        viewModel.clearResult()
    }

    // Surface one-off info messages (e.g. a logo skipped because it's already in
    // the other section).
    LaunchedEffect(state.messageRes) {
        val res = state.messageRes ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(context.getString(res))
        viewModel.clearMessage()
    }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.app_name)) })
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            // ---- Locked live preview: stays visible while the steps scroll ----
            if (state.photoUris.isNotEmpty() && state.hasAnyLogo) {
                LockedPreview(
                    photoUris = state.photoUris.take(MAX_PREVIEW),
                    logoUris = state.logos.map { it.uri },
                    topLeftLogoUris = state.topLeftLogos.map { it.uri },
                    cornerLogoUri = state.cornerLogoUri,
                    logoHeightPercent = state.logoHeightPercent,
                    leftMarginPercent = state.leftMarginPercent,
                    logoOpacityPercent = state.logoOpacityPercent,
                    bottomMarginPercent = state.bottomMarginPercent,
                    topMarginPercent = state.topMarginPercent,
                    cornerLogoHeightPercent = state.cornerLogoHeightPercent,
                    cornerMarginPercent = state.cornerMarginPercent
                )
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
            // ---- Step 1: photos ----
            StepCard(
                number = 1,
                title = stringResource(R.string.step_photos),
                icon = { Icon(Icons.Filled.PhotoLibrary, contentDescription = null) }
            ) {
                Button(
                    onClick = {
                        photoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Filled.AddPhotoAlternate, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.add_photos))
                }
                if (state.photoUris.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = stringResource(R.string.photos_selected, state.photoUris.size),
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium
                    )
                    Spacer(Modifier.height(8.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(state.photoUris, key = { it.toString() }) { uri ->
                            RemovableThumbnail(
                                uri = uri,
                                contentScale = ContentScale.Crop,
                                onRemove = { viewModel.removePhoto(uri) }
                            )
                        }
                    }
                }
            }

            // ---- Step 2: bottom logos ----
            StepCard(
                number = 2,
                title = stringResource(R.string.step_bottom_logos),
                icon = { PlacementIcon(Placement.BOTTOM) }
            ) {
                MultiLogoPicker(
                    enabled = state.photoUris.isNotEmpty(),
                    items = state.logos,
                    hint = stringResource(
                        if (state.photoUris.isEmpty()) R.string.logo_hint
                        else R.string.bottom_logos_hint
                    ),
                    onAdd = {
                        logoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    onRemove = { viewModel.removeLogo(it) },
                    onMove = { from, to -> viewModel.moveLogo(from, to) }
                )
                if (state.logos.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_size_all, state.logoHeightPercent.roundToInt()),
                        value = state.logoHeightPercent,
                        valueRange = 5f..30f,
                        onValueChange = viewModel::setLogoHeightPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.left_margin_all, state.leftMarginPercent.roundToInt()),
                        value = state.leftMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setLeftMarginPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_opacity_all, state.logoOpacityPercent.roundToInt()),
                        value = state.logoOpacityPercent,
                        valueRange = 0f..100f,
                        onValueChange = viewModel::setLogoOpacityPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.bottom_margin, state.bottomMarginPercent.roundToInt()),
                        value = state.bottomMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setBottomMarginPercent
                    )
                }
            }

            // ---- Step 3: top-left logos ----
            StepCard(
                number = 3,
                title = stringResource(R.string.step_top_left_logos),
                icon = { PlacementIcon(Placement.TOP_LEFT) }
            ) {
                MultiLogoPicker(
                    enabled = state.photoUris.isNotEmpty(),
                    items = state.topLeftLogos,
                    hint = stringResource(
                        if (state.photoUris.isEmpty()) R.string.logo_hint
                        else R.string.top_left_logos_hint
                    ),
                    onAdd = {
                        topLeftLogoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    onRemove = { viewModel.removeTopLeftLogo(it) },
                    onMove = { from, to -> viewModel.moveTopLeftLogo(from, to) }
                )
                if (state.topLeftLogos.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_size_all, state.logoHeightPercent.roundToInt()),
                        value = state.logoHeightPercent,
                        valueRange = 5f..30f,
                        onValueChange = viewModel::setLogoHeightPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.left_margin_all, state.leftMarginPercent.roundToInt()),
                        value = state.leftMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setLeftMarginPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_opacity_all, state.logoOpacityPercent.roundToInt()),
                        value = state.logoOpacityPercent,
                        valueRange = 0f..100f,
                        onValueChange = viewModel::setLogoOpacityPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.top_margin, state.topMarginPercent.roundToInt()),
                        value = state.topMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setTopMarginPercent
                    )
                }
            }

            // ---- Step 4: main company logo (top-right, single) ----
            StepCard(
                number = 4,
                title = stringResource(R.string.step_corner_logo),
                icon = { PlacementIcon(Placement.TOP_RIGHT) }
            ) {
                OutlinedButton(
                    onClick = {
                        cornerLogoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    enabled = state.photoUris.isNotEmpty(),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Filled.Image, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        stringResource(
                            if (state.cornerLogoUri == null) R.string.add_corner_logo
                            else R.string.change_corner_logo
                        )
                    )
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    text = stringResource(R.string.corner_logo_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (state.cornerLogoUri != null) {
                    Spacer(Modifier.height(12.dp))
                    RemovableThumbnail(
                        uri = state.cornerLogoUri!!,
                        contentScale = ContentScale.Fit,
                        onRemove = { viewModel.setCornerLogo(null) }
                    )
                    Spacer(Modifier.height(12.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_size, state.cornerLogoHeightPercent.roundToInt()),
                        value = state.cornerLogoHeightPercent,
                        valueRange = 5f..30f,
                        onValueChange = viewModel::setCornerLogoHeightPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.corner_margin, state.cornerMarginPercent.roundToInt()),
                        value = state.cornerMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setCornerMarginPercent
                    )
                }
            }

            // ---- Action ----
            if (state.isProcessing) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    LinearProgressIndicator(
                        progress = {
                            if (state.total == 0) 0f
                            else state.processed.toFloat() / state.total.toFloat()
                        },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(R.string.processing, state.processed, state.total),
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            } else {
                Button(
                    onClick = { startProcessing() },
                    enabled = state.canProcess,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(52.dp)
                ) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.apply_and_save), fontSize = 16.sp)
                }
                Text(
                    text = stringResource(R.string.save_location),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth()
                )
            }
            }
        }
    }
}

@Composable
private fun StepCard(
    number: Int,
    title: String,
    icon: @Composable () -> Unit,
    content: @Composable () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                ) {
                    Text(
                        text = number.toString(),
                        color = MaterialTheme.colorScheme.onPrimary,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp
                    )
                }
                Spacer(Modifier.width(10.dp))
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.size(28.dp)
                ) { icon() }
                Spacer(Modifier.width(10.dp))
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Spacer(Modifier.height(12.dp))
            content()
        }
    }
}

@Composable
private fun RemovableThumbnail(
    uri: Uri,
    contentScale: ContentScale,
    onRemove: () -> Unit
) {
    Box(modifier = Modifier.size(76.dp)) {
        AsyncImage(
            model = uri,
            contentDescription = null,
            contentScale = contentScale,
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
        )
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(2.dp)
                .size(22.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.6f))
                .clickable { onRemove() }
        ) {
            Icon(
                Icons.Filled.Close,
                contentDescription = stringResource(R.string.remove_photo),
                tint = Color.White,
                modifier = Modifier.size(14.dp)
            )
        }
    }
}

@Composable
private fun MultiLogoPicker(
    enabled: Boolean,
    items: List<LogoItem>,
    hint: String,
    onAdd: () -> Unit,
    onRemove: (Long) -> Unit,
    onMove: (Int, Int) -> Unit
) {
    OutlinedButton(
        onClick = onAdd,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth()
    ) {
        Icon(Icons.Filled.Image, contentDescription = null)
        Spacer(Modifier.width(8.dp))
        Text(stringResource(R.string.add_logos))
    }
    Spacer(Modifier.height(8.dp))
    Text(
        text = hint,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
    if (items.isNotEmpty()) {
        Spacer(Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.logos_selected, items.size),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium
        )
        if (items.size > 1) {
            Text(
                text = stringResource(R.string.reorder_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(Modifier.height(8.dp))
        ReorderableLogoList(items = items, onRemove = onRemove, onMove = onMove)
    }
}

/**
 * Vertical list of logos reordered by long-pressing the drag handle and dragging
 * up or down. The dragged row follows the finger; the rows it passes animate
 * into place ([animateItemPlacement]). The dragged index is tracked locally, so
 * a single fast drag can move a logo across many positions (e.g. first to last)
 * in one motion. Top-to-bottom here is the same as left-to-right in the photo.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ReorderableLogoList(
    items: List<LogoItem>,
    onRemove: (Long) -> Unit,
    onMove: (Int, Int) -> Unit
) {
    val rowHeight = 64.dp
    val rowHeightPx = with(LocalDensity.current) { rowHeight.toPx() }
    val latestItems by rememberUpdatedState(items)
    val scope = rememberCoroutineScope()

    var draggedId by remember { mutableStateOf<Long?>(null) }
    var draggedIndex by remember { mutableIntStateOf(-1) }
    var dragOffset by remember { mutableFloatStateOf(0f) }

    LazyColumn(
        userScrollEnabled = false,
        modifier = Modifier
            .fillMaxWidth()
            .height(rowHeight * items.size)
    ) {
        itemsIndexed(items, key = { _, item -> item.id }) { index, item ->
            val isDragging = item.id == draggedId
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(rowHeight)
                    .then(
                        if (isDragging) {
                            Modifier
                                .zIndex(1f)
                                .graphicsLayer { translationY = dragOffset }
                        } else {
                            Modifier.animateItemPlacement()
                        }
                    )
            ) {
                AsyncImage(
                    model = item.uri,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                )
                Text(
                    text = stringResource(R.string.logo_position, index + 1),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 12.dp)
                )
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .clickable { onRemove(item.id) }
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = stringResource(R.string.remove_logo),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp)
                    )
                }
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(44.dp)
                        .pointerInput(item.id) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = {
                                    draggedId = item.id
                                    draggedIndex = latestItems.indexOfFirst { it.id == item.id }
                                    dragOffset = 0f
                                },
                                onDragEnd = {
                                    val start = dragOffset
                                    scope.launch {
                                        animate(start, 0f, animationSpec = tween(140)) { v, _ ->
                                            dragOffset = v
                                        }
                                        draggedId = null
                                        draggedIndex = -1
                                        dragOffset = 0f
                                    }
                                },
                                onDragCancel = {
                                    val start = dragOffset
                                    scope.launch {
                                        animate(start, 0f, animationSpec = tween(140)) { v, _ ->
                                            dragOffset = v
                                        }
                                        draggedId = null
                                        draggedIndex = -1
                                        dragOffset = 0f
                                    }
                                },
                                onDrag = { change, dragAmount ->
                                    change.consume()
                                    dragOffset += dragAmount.y
                                    val last = latestItems.lastIndex
                                    // Step through as many positions as the offset covers,
                                    // so one fast drag can move across the whole list.
                                    while (dragOffset > rowHeightPx / 2f && draggedIndex in 0 until last) {
                                        onMove(draggedIndex, draggedIndex + 1)
                                        draggedIndex++
                                        dragOffset -= rowHeightPx
                                    }
                                    while (dragOffset < -rowHeightPx / 2f && draggedIndex > 0) {
                                        onMove(draggedIndex, draggedIndex - 1)
                                        draggedIndex--
                                        dragOffset += rowHeightPx
                                    }
                                }
                            )
                        }
                ) {
                    Icon(
                        Icons.Filled.DragHandle,
                        contentDescription = stringResource(R.string.reorder_hint),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

/** Loads a list of logo uris, decoding each distinct uri only once. */
private fun loadLogos(context: android.content.Context, uris: List<Uri>): List<Bitmap> {
    val cache = HashMap<Uri, Bitmap?>()
    return uris.mapNotNull { uri ->
        cache.getOrPut(uri) {
            WatermarkEngine.loadBitmap(context.contentResolver, uri, maxDimension = 1080)
        }
    }
}

/**
 * Live watermarked preview of the first few photos (up to [MAX_PREVIEW]), pinned
 * at the top of the screen (inside an elevated [Surface]) so it stays visible
 * while the steps below it scroll. Swipe horizontally to flip between photos.
 */
@Composable
private fun LockedPreview(
    photoUris: List<Uri>,
    logoUris: List<Uri>,
    topLeftLogoUris: List<Uri>,
    cornerLogoUri: Uri?,
    logoHeightPercent: Float,
    leftMarginPercent: Float,
    logoOpacityPercent: Float,
    bottomMarginPercent: Float,
    topMarginPercent: Float,
    cornerLogoHeightPercent: Float,
    cornerMarginPercent: Float
) {
    val context = LocalContext.current

    // Downscaled source bitmaps, reloaded only when the photos/logos actually change.
    var sources by remember(photoUris) { mutableStateOf<List<Bitmap>?>(null) }
    var logos by remember(logoUris) { mutableStateOf<List<Bitmap>?>(null) }
    var topLeftLogos by remember(topLeftLogoUris) { mutableStateOf<List<Bitmap>?>(null) }
    var cornerLogo by remember(cornerLogoUri) { mutableStateOf<Bitmap?>(null) }

    LaunchedEffect(photoUris) {
        sources = withContext(Dispatchers.Default) {
            photoUris.mapNotNull {
                WatermarkEngine.loadBitmap(context.contentResolver, it, maxDimension = 900)
            }
        }
    }
    LaunchedEffect(logoUris) {
        logos = withContext(Dispatchers.Default) { loadLogos(context, logoUris) }
    }
    LaunchedEffect(topLeftLogoUris) {
        topLeftLogos = withContext(Dispatchers.Default) { loadLogos(context, topLeftLogoUris) }
    }
    LaunchedEffect(cornerLogoUri) {
        cornerLogo = withContext(Dispatchers.Default) {
            cornerLogoUri?.let { WatermarkEngine.loadBitmap(context.contentResolver, it, maxDimension = 1080) }
        }
    }

    // Recompose every preview whenever a source or a placement setting changes.
    val srcs = sources
    val lg = logos
    val tl = topLeftLogos
    val corner = cornerLogo
    var previews by remember { mutableStateOf<List<Bitmap>>(emptyList()) }
    LaunchedEffect(
        srcs, lg, tl, corner,
        logoHeightPercent, leftMarginPercent, logoOpacityPercent, bottomMarginPercent,
        topMarginPercent, cornerLogoHeightPercent, cornerMarginPercent
    ) {
        if (srcs != null && lg != null && tl != null &&
            (lg.isNotEmpty() || tl.isNotEmpty() || corner != null)
        ) {
            previews = withContext(Dispatchers.Default) {
                srcs.map { src ->
                    WatermarkEngine.applyWatermarks(
                        photo = src,
                        bottomLogos = lg,
                        topLeftLogos = tl,
                        cornerLogo = corner,
                        bottomLogoHeightFraction = logoHeightPercent / 100f,
                        bottomMarginFraction = bottomMarginPercent / 100f,
                        bottomLeftMarginFraction = leftMarginPercent / 100f,
                        topLeftLogoHeightFraction = logoHeightPercent / 100f,
                        topLeftTopMarginFraction = topMarginPercent / 100f,
                        topLeftLeftMarginFraction = leftMarginPercent / 100f,
                        cornerLogoHeightFraction = cornerLogoHeightPercent / 100f,
                        cornerMarginFraction = cornerMarginPercent / 100f,
                        rowLogoOpacity = logoOpacityPercent / 100f
                    )
                }
            }
        }
    }

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shadowElevation = 4.dp,
        color = MaterialTheme.colorScheme.surface
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text(
                text = if (photoUris.size <= 1) stringResource(R.string.preview_label)
                else stringResource(R.string.preview_label_n, photoUris.size),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(6.dp))
            if (previews.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 120.dp, max = 220.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator(modifier = Modifier.padding(24.dp))
                }
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    itemsIndexed(previews) { index, bmp ->
                        Box(
                            modifier = Modifier
                                .fillParentMaxWidth(if (previews.size > 1) 0.9f else 1f)
                                .heightIn(min = 120.dp, max = 220.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant),
                            contentAlignment = Alignment.Center
                        ) {
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = stringResource(R.string.preview_label),
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize()
                            )
                            if (previews.size > 1) {
                                Text(
                                    text = "${index + 1}/${previews.size}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color.White,
                                    modifier = Modifier
                                        .align(Alignment.TopStart)
                                        .padding(6.dp)
                                        .clip(RoundedCornerShape(6.dp))
                                        .background(Color.Black.copy(alpha = 0.5f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Which corner/edge a step's logos occupy, used by [PlacementIcon]. */
private enum class Placement { BOTTOM, TOP_LEFT, TOP_RIGHT }

/**
 * A small glyph showing a 16:9 frame with the relevant region highlighted, so
 * each step visually communicates where its logos land.
 */
@Composable
private fun PlacementIcon(placement: Placement, modifier: Modifier = Modifier.size(28.dp)) {
    val color = MaterialTheme.colorScheme.primary
    Canvas(modifier = modifier) {
        val frameW = size.width
        val frameH = frameW * 9f / 16f
        val top = (size.height - frameH) / 2f
        val corner = CornerRadius(frameH * 0.14f, frameH * 0.14f)
        val stroke = (frameH * 0.09f).coerceAtLeast(2f)

        // 16:9 frame outline.
        drawRoundRect(
            color = color,
            topLeft = Offset(stroke / 2f, top + stroke / 2f),
            size = Size(frameW - stroke, frameH - stroke),
            cornerRadius = corner,
            style = Stroke(width = stroke)
        )

        // Highlighted region for this placement.
        val pad = frameW * 0.16f
        when (placement) {
            Placement.BOTTOM -> {
                val barH = frameH * 0.24f
                drawRoundRect(
                    color = color,
                    topLeft = Offset(pad, top + frameH - pad - barH),
                    size = Size(frameW - pad * 2f, barH),
                    cornerRadius = CornerRadius(barH / 2f, barH / 2f)
                )
            }
            Placement.TOP_LEFT -> {
                val boxW = frameW * 0.42f
                val boxH = frameH * 0.26f
                drawRoundRect(
                    color = color,
                    topLeft = Offset(pad, top + pad),
                    size = Size(boxW, boxH),
                    cornerRadius = CornerRadius(boxH / 2f, boxH / 2f)
                )
            }
            Placement.TOP_RIGHT -> {
                val boxW = frameW * 0.30f
                val boxH = frameH * 0.30f
                drawRoundRect(
                    color = color,
                    topLeft = Offset(frameW - pad - boxW, top + pad),
                    size = Size(boxW, boxH),
                    cornerRadius = CornerRadius(boxH * 0.3f, boxH * 0.3f)
                )
            }
        }
    }
}

@Composable
private fun LabeledSlider(
    label: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit
) {
    Column {
        Text(label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
        Slider(value = value, onValueChange = onValueChange, valueRange = valueRange)
    }
}

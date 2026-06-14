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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Image
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
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.tekz.watermark.ui.theme.PhotoWatermarkTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

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
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // ---- Step 1: photos ----
            StepCard(number = 1, title = stringResource(R.string.step_photos)) {
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
            StepCard(number = 2, title = stringResource(R.string.step_bottom_logos)) {
                MultiLogoPicker(
                    enabled = state.photoUris.isNotEmpty(),
                    uris = state.logoUris,
                    hint = stringResource(
                        if (state.photoUris.isEmpty()) R.string.logo_hint
                        else R.string.bottom_logos_hint
                    ),
                    onAdd = {
                        logoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    onRemove = { viewModel.removeLogo(it) }
                )
                if (state.logoUris.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_size, state.logoHeightPercent.roundToInt()),
                        value = state.logoHeightPercent,
                        valueRange = 5f..30f,
                        onValueChange = viewModel::setLogoHeightPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.bottom_margin, state.bottomMarginPercent.roundToInt()),
                        value = state.bottomMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setBottomMarginPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.left_margin, state.bottomLeftMarginPercent.roundToInt()),
                        value = state.bottomLeftMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setBottomLeftMarginPercent
                    )
                }
            }

            // ---- Step 3: top-left logos ----
            StepCard(number = 3, title = stringResource(R.string.step_top_left_logos)) {
                MultiLogoPicker(
                    enabled = state.photoUris.isNotEmpty(),
                    uris = state.topLeftLogoUris,
                    hint = stringResource(
                        if (state.photoUris.isEmpty()) R.string.logo_hint
                        else R.string.top_left_logos_hint
                    ),
                    onAdd = {
                        topLeftLogoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    onRemove = { viewModel.removeTopLeftLogo(it) }
                )
                if (state.topLeftLogoUris.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    LabeledSlider(
                        label = stringResource(R.string.logo_size, state.topLeftLogoHeightPercent.roundToInt()),
                        value = state.topLeftLogoHeightPercent,
                        valueRange = 5f..30f,
                        onValueChange = viewModel::setTopLeftLogoHeightPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.top_margin, state.topLeftTopMarginPercent.roundToInt()),
                        value = state.topLeftTopMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setTopLeftTopMarginPercent
                    )
                    Spacer(Modifier.height(8.dp))
                    LabeledSlider(
                        label = stringResource(R.string.left_margin, state.topLeftLeftMarginPercent.roundToInt()),
                        value = state.topLeftLeftMarginPercent,
                        valueRange = 0f..15f,
                        onValueChange = viewModel::setTopLeftLeftMarginPercent
                    )
                }
            }

            // ---- Step 4: main company logo (top-right, single) ----
            StepCard(number = 4, title = stringResource(R.string.step_corner_logo)) {
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

            // ---- Step 5: preview ----
            val firstPhoto = state.photoUris.firstOrNull()
            if (firstPhoto != null && state.hasAnyLogo) {
                StepCard(number = 5, title = stringResource(R.string.step_preview)) {
                    Text(
                        text = stringResource(R.string.preview_label),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Medium
                    )
                    Spacer(Modifier.height(8.dp))
                    WatermarkPreview(
                        photoUri = firstPhoto,
                        logoUris = state.logoUris,
                        topLeftLogoUris = state.topLeftLogoUris,
                        cornerLogoUri = state.cornerLogoUri,
                        logoHeightPercent = state.logoHeightPercent,
                        bottomMarginPercent = state.bottomMarginPercent,
                        bottomLeftMarginPercent = state.bottomLeftMarginPercent,
                        topLeftLogoHeightPercent = state.topLeftLogoHeightPercent,
                        topLeftTopMarginPercent = state.topLeftTopMarginPercent,
                        topLeftLeftMarginPercent = state.topLeftLeftMarginPercent,
                        cornerLogoHeightPercent = state.cornerLogoHeightPercent,
                        cornerMarginPercent = state.cornerMarginPercent
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

@Composable
private fun StepCard(number: Int, title: String, content: @Composable () -> Unit) {
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
                Spacer(Modifier.width(12.dp))
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
    uris: List<Uri>,
    hint: String,
    onAdd: () -> Unit,
    onRemove: (Uri) -> Unit
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
    if (uris.isNotEmpty()) {
        Spacer(Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.logos_selected, uris.size),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium
        )
        Spacer(Modifier.height(8.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(uris, key = { it.toString() }) { uri ->
                RemovableThumbnail(
                    uri = uri,
                    contentScale = ContentScale.Fit,
                    onRemove = { onRemove(uri) }
                )
            }
        }
    }
}

@Composable
private fun WatermarkPreview(
    photoUri: Uri,
    logoUris: List<Uri>,
    topLeftLogoUris: List<Uri>,
    cornerLogoUri: Uri?,
    logoHeightPercent: Float,
    bottomMarginPercent: Float,
    bottomLeftMarginPercent: Float,
    topLeftLogoHeightPercent: Float,
    topLeftTopMarginPercent: Float,
    topLeftLeftMarginPercent: Float,
    cornerLogoHeightPercent: Float,
    cornerMarginPercent: Float
) {
    val context = LocalContext.current

    // Downscaled source bitmaps, reloaded only when the photo/logos actually change.
    var source by remember(photoUri) { mutableStateOf<Bitmap?>(null) }
    var logos by remember(logoUris) { mutableStateOf<List<Bitmap>?>(null) }
    var topLeftLogos by remember(topLeftLogoUris) { mutableStateOf<List<Bitmap>?>(null) }
    var cornerLogo by remember(cornerLogoUri) { mutableStateOf<Bitmap?>(null) }

    LaunchedEffect(photoUri) {
        source = withContext(Dispatchers.Default) {
            WatermarkEngine.loadBitmap(context.contentResolver, photoUri, maxDimension = 1080)
        }
    }
    LaunchedEffect(logoUris) {
        logos = withContext(Dispatchers.Default) {
            logoUris.mapNotNull { WatermarkEngine.loadBitmap(context.contentResolver, it, maxDimension = 1080) }
        }
    }
    LaunchedEffect(topLeftLogoUris) {
        topLeftLogos = withContext(Dispatchers.Default) {
            topLeftLogoUris.mapNotNull { WatermarkEngine.loadBitmap(context.contentResolver, it, maxDimension = 1080) }
        }
    }
    LaunchedEffect(cornerLogoUri) {
        cornerLogo = withContext(Dispatchers.Default) {
            cornerLogoUri?.let { WatermarkEngine.loadBitmap(context.contentResolver, it, maxDimension = 1080) }
        }
    }

    // Recompose the watermarked preview whenever a source or a placement setting changes.
    val src = source
    val lg = logos
    val tl = topLeftLogos
    val corner = cornerLogo
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(
        src, lg, tl, corner,
        logoHeightPercent, bottomMarginPercent, bottomLeftMarginPercent,
        topLeftLogoHeightPercent, topLeftTopMarginPercent, topLeftLeftMarginPercent,
        cornerLogoHeightPercent, cornerMarginPercent
    ) {
        if (src != null && lg != null && tl != null &&
            (lg.isNotEmpty() || tl.isNotEmpty() || corner != null)
        ) {
            preview = withContext(Dispatchers.Default) {
                WatermarkEngine.applyWatermarks(
                    photo = src,
                    bottomLogos = lg,
                    topLeftLogos = tl,
                    cornerLogo = corner,
                    bottomLogoHeightFraction = logoHeightPercent / 100f,
                    bottomMarginFraction = bottomMarginPercent / 100f,
                    bottomLeftMarginFraction = bottomLeftMarginPercent / 100f,
                    topLeftLogoHeightFraction = topLeftLogoHeightPercent / 100f,
                    topLeftTopMarginFraction = topLeftTopMarginPercent / 100f,
                    topLeftLeftMarginFraction = topLeftLeftMarginPercent / 100f,
                    cornerLogoHeightFraction = cornerLogoHeightPercent / 100f,
                    cornerMarginFraction = cornerMarginPercent / 100f
                )
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 120.dp, max = 360.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center
    ) {
        val bmp = preview
        if (bmp != null) {
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = stringResource(R.string.preview_label),
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxWidth()
            )
        } else {
            CircularProgressIndicator(modifier = Modifier.padding(24.dp))
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

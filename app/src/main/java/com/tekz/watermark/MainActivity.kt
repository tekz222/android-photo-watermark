package com.tekz.watermark

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.NorthWest
import androidx.compose.material.icons.filled.SouthEast
import androidx.compose.material.icons.filled.SouthWest
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
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
            state.groups.forEachIndexed { index, group ->
                key(group.id) {
                    GroupCard(
                        index = index,
                        group = group,
                        canDelete = state.groups.size > 1,
                        onAddPhotos = { viewModel.addPhotos(group.id, it) },
                        onRemovePhoto = { viewModel.removePhoto(group.id, it) },
                        onPickLogo = { viewModel.setLogo(group.id, it) },
                        onCorner = { viewModel.setCorner(group.id, it) },
                        onSize = { viewModel.setLogoWidthPercent(group.id, it) },
                        onPadding = { viewModel.setPaddingPercent(group.id, it) },
                        onDelete = { viewModel.removeGroup(group.id) }
                    )
                }
            }

            OutlinedButton(
                onClick = { viewModel.addGroup() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.Add, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.add_group))
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
private fun GroupCard(
    index: Int,
    group: WatermarkGroup,
    canDelete: Boolean,
    onAddPhotos: (List<Uri>) -> Unit,
    onRemovePhoto: (Uri) -> Unit,
    onPickLogo: (Uri?) -> Unit,
    onCorner: (Corner) -> Unit,
    onSize: (Float) -> Unit,
    onPadding: (Float) -> Unit,
    onDelete: () -> Unit
) {
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris -> if (uris.isNotEmpty()) onAddPhotos(uris) }

    val logoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> onPickLogo(uri) }

    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Header: numbered badge + title + delete
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                ) {
                    Text(
                        text = (index + 1).toString(),
                        color = MaterialTheme.colorScheme.onPrimary,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp
                    )
                }
                Spacer(Modifier.width(12.dp))
                Text(
                    text = stringResource(R.string.group_title, index + 1),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.weight(1f))
                if (canDelete) {
                    IconButton(onClick = onDelete) {
                        Icon(
                            Icons.Filled.Delete,
                            contentDescription = stringResource(R.string.delete_group),
                            tint = MaterialTheme.colorScheme.error
                        )
                    }
                }
            }

            // Photos
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
            if (group.photoUris.isNotEmpty()) {
                Text(
                    text = stringResource(R.string.photos_selected, group.photoUris.size),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium
                )
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(group.photoUris, key = { it.toString() }) { uri ->
                        RemovableThumbnail(uri = uri, onRemove = { onRemovePhoto(uri) })
                    }
                }
            }

            // Logo
            OutlinedButton(
                onClick = {
                    logoPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    )
                },
                enabled = group.photoUris.isNotEmpty(),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.Image, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.select_logo))
            }
            if (group.photoUris.isEmpty()) {
                Text(
                    text = stringResource(R.string.logo_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            group.logoUri?.let { logo ->
                AsyncImage(
                    model = logo,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(96.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(8.dp)
                )
            }

            // Position
            Text(
                text = stringResource(R.string.position_label),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Medium
            )
            CornerSelector(selected = group.corner, onSelect = onCorner)

            // Fine tuning
            LabeledSlider(
                label = stringResource(R.string.logo_size, group.logoWidthPercent.roundToInt()),
                value = group.logoWidthPercent,
                valueRange = 5f..40f,
                onValueChange = onSize
            )
            LabeledSlider(
                label = stringResource(R.string.padding, group.paddingPercent.roundToInt()),
                value = group.paddingPercent,
                valueRange = 0f..15f,
                onValueChange = onPadding
            )
        }
    }
}

@Composable
private fun RemovableThumbnail(uri: Uri, onRemove: () -> Unit) {
    Box(modifier = Modifier.size(76.dp)) {
        AsyncImage(
            model = uri,
            contentDescription = null,
            contentScale = ContentScale.Crop,
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
private fun CornerSelector(selected: Corner, onSelect: (Corner) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CornerButton(Corner.TOP_LEFT, Icons.Filled.NorthWest, selected, onSelect, Modifier.weight(1f))
            CornerButton(Corner.TOP_RIGHT, Icons.Filled.NorthEast, selected, onSelect, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CornerButton(Corner.BOTTOM_LEFT, Icons.Filled.SouthWest, selected, onSelect, Modifier.weight(1f))
            CornerButton(Corner.BOTTOM_RIGHT, Icons.Filled.SouthEast, selected, onSelect, Modifier.weight(1f))
        }
    }
}

@Composable
private fun CornerButton(
    corner: Corner,
    icon: ImageVector,
    selected: Corner,
    onSelect: (Corner) -> Unit,
    modifier: Modifier = Modifier
) {
    val isSelected = corner == selected
    val border = if (isSelected) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.outlineVariant
    val container = if (isSelected) MaterialTheme.colorScheme.primaryContainer
        else MaterialTheme.colorScheme.surface
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .aspectRatio(1.8f)
            .clip(RoundedCornerShape(12.dp))
            .background(container)
            .border(if (isSelected) 2.dp else 1.dp, border, RoundedCornerShape(12.dp))
            .clickable { onSelect(corner) }
    ) {
        Icon(
            imageVector = icon,
            contentDescription = corner.name,
            tint = if (isSelected) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant
        )
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

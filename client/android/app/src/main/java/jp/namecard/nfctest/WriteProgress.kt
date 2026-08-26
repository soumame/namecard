package jp.namecard.nfctest

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import kotlin.math.roundToInt

internal enum class WriteProgressOutcome {
    RUNNING,
    COMPLETE,
    INTERRUPTED,
}

internal data class NfcAntennaPoint(
    val xRatio: Float,
    val yRatioFromTop: Float,
)

internal data class NfcAntennaGuide(
    val deviceWidthMm: Int,
    val deviceHeightMm: Int,
    val points: List<NfcAntennaPoint>,
    val deviceReported: Boolean,
) {
    companion object {
        fun fallback() = NfcAntennaGuide(
            deviceWidthMm = 1,
            deviceHeightMm = 2,
            points = listOf(NfcAntennaPoint(xRatio = 0.5f, yRatioFromTop = 0.18f)),
            deviceReported = false,
        )
    }
}

internal fun nfcAntennaGuide(
    deviceWidthMm: Int,
    deviceHeightMm: Int,
    locationsMm: List<Pair<Int, Int>>,
): NfcAntennaGuide? {
    if (deviceWidthMm <= 0 || deviceHeightMm <= 0 || locationsMm.isEmpty()) return null
    return NfcAntennaGuide(
        deviceWidthMm = deviceWidthMm,
        deviceHeightMm = deviceHeightMm,
        points = locationsMm.map { (x, y) ->
            NfcAntennaPoint(
                xRatio = (x.toFloat() / deviceWidthMm).coerceIn(0f, 1f),
                yRatioFromTop = (y.toFloat() / deviceHeightMm).coerceIn(0f, 1f),
            )
        },
        deviceReported = true,
    )
}

internal enum class NfcLinkLevel {
    GOOD,
    FAIR,
    WEAK,
    LOST,
}

internal data class NfcLinkStatus(
    val level: NfcLinkLevel,
    val vddMv: Int,
    val responseMillis: Long,
    val recentIssues: Int,
)

internal fun nfcLinkStatus(
    vddMv: Int,
    responseMillis: Long,
    recentIssues: Int,
): NfcLinkStatus {
    val issues = recentIssues.coerceAtLeast(0)
    val level = when {
        issues >= 2 || vddMv in 1 until 3_050 || responseMillis >= 800L -> NfcLinkLevel.WEAK
        issues == 1 || vddMv in 3_050 until 3_200 || responseMillis >= 350L -> NfcLinkLevel.FAIR
        else -> NfcLinkLevel.GOOD
    }
    return NfcLinkStatus(level, vddMv.coerceAtLeast(0), responseMillis.coerceAtLeast(0), issues)
}

internal data class WriteProgressState(
    val title: String,
    val progress: Float = 0f,
    val currentStep: Int = 1,
    val status: String = "名刺にタッチしてください",
    val detail: String = "Pixelと名刺の位置を固定すると、途中から自動的に処理が始まります。",
    val outcome: WriteProgressOutcome = WriteProgressOutcome.RUNNING,
    val canCancel: Boolean = true,
    val antennaGuide: NfcAntennaGuide = NfcAntennaGuide.fallback(),
    val linkStatus: NfcLinkStatus? = null,
) {
    val percent: Int get() = (progress.coerceIn(0f, 1f) * 100f).roundToInt()
    val canDismiss: Boolean get() = outcome != WriteProgressOutcome.RUNNING || canCancel
}

internal fun imageTransferProgress(transferredBytes: Int, totalBytes: Int): Float {
    if (totalBytes <= 0) return DATA_PROGRESS_START
    val ratio = transferredBytes.coerceIn(0, totalBytes).toFloat() / totalBytes
    return DATA_PROGRESS_START + ratio * (DATA_PROGRESS_END - DATA_PROGRESS_START)
}

@Composable
internal fun WriteProgressDialog(
    state: WriteProgressState,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = { if (state.canDismiss) onDismiss() }) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = MaterialTheme.shapes.extraLarge,
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp,
        ) {
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "NFC書き込み",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            state.title,
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            maxLines = 2,
                        )
                    }
                    Text(
                        "${state.percent}%",
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                    )
                }

                LinearProgressIndicator(
                    progress = { state.progress.coerceIn(0f, 1f) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(8.dp)
                        .clip(CircleShape),
                )

                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = when (state.outcome) {
                        WriteProgressOutcome.INTERRUPTED -> MaterialTheme.colorScheme.errorContainer
                        else -> MaterialTheme.colorScheme.secondaryContainer
                    },
                    contentColor = when (state.outcome) {
                        WriteProgressOutcome.INTERRUPTED -> MaterialTheme.colorScheme.onErrorContainer
                        else -> MaterialTheme.colorScheme.onSecondaryContainer
                    },
                ) {
                    Column(
                        modifier = Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            state.status,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(state.detail, style = MaterialTheme.typography.bodySmall)
                    }
                }

                if (state.currentStep == 1 || state.outcome == WriteProgressOutcome.INTERRUPTED) {
                    NfcAntennaPlacementGuide(state.antennaGuide)
                }

                state.linkStatus?.let { NfcLinkStatusCard(it) }

                Text(
                    "処理ステップ",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    progressSteps.forEachIndexed { index, step ->
                        ProgressStepItem(
                            number = index + 1,
                            label = step.label,
                            iconRes = step.iconRes,
                            active = index + 1 == state.currentStep,
                            complete = index + 1 < state.currentStep ||
                                state.outcome == WriteProgressOutcome.COMPLETE,
                        )
                    }
                }

                if (state.outcome == WriteProgressOutcome.RUNNING && !state.canCancel) {
                    Text(
                        "完了するまで端末を動かさないでください",
                        modifier = Modifier.fillMaxWidth(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                } else if (state.canCancel) {
                    TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                        Text("キャンセル")
                    }
                } else {
                    Button(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                        Text("閉じる")
                    }
                }
            }
        }
    }
}

@Composable
private fun NfcAntennaPlacementGuide(guide: NfcAntennaGuide) {
    val outline = MaterialTheme.colorScheme.outline
    val marker = MaterialTheme.colorScheme.primary
    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.tertiaryContainer,
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Canvas(
                modifier = Modifier
                    .width(58.dp)
                    .aspectRatio(
                        guide.deviceWidthMm.toFloat() / guide.deviceHeightMm.coerceAtLeast(1),
                    ),
            ) {
                drawRoundRect(
                    color = outline,
                    cornerRadius = CornerRadius(9.dp.toPx()),
                    style = Stroke(width = 2.dp.toPx()),
                )
                guide.points.forEach { point ->
                    val center = Offset(
                        x = size.width * point.xRatio,
                        y = size.height * point.yRatioFromTop,
                    )
                    drawCircle(marker.copy(alpha = 0.22f), radius = 13.dp.toPx(), center = center)
                    drawCircle(marker, radius = 5.dp.toPx(), center = center)
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("この位置に名刺を合わせます", fontWeight = FontWeight.SemiBold)
                Text(
                    "画面側から見た印の位置へ、名刺を端末の背面から重ねてください。",
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    if (guide.deviceReported) {
                        "端末が公開したNFCアンテナ座標を使用中"
                    } else {
                        "アンテナ座標を取得できないため一般的な目安を表示中"
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onTertiaryContainer.copy(alpha = 0.75f),
                )
            }
        }
    }
}

@Composable
private fun NfcLinkStatusCard(status: NfcLinkStatus) {
    val (label, color) = when (status.level) {
        NfcLinkLevel.GOOD -> "安定" to MaterialTheme.colorScheme.primary
        NfcLinkLevel.FAIR -> "やや弱い" to MaterialTheme.colorScheme.tertiary
        NfcLinkLevel.WEAK -> "位置を調整" to MaterialTheme.colorScheme.error
        NfcLinkLevel.LOST -> "切断" to MaterialTheme.colorScheme.error
    }
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = color.copy(alpha = 0.12f),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(modifier = Modifier.size(12.dp), shape = CircleShape, color = color) {}
            Column(modifier = Modifier.weight(1f)) {
                Text("通信状態：$label", fontWeight = FontWeight.SemiBold)
                Text(
                    buildString {
                        if (status.vddMv > 0) append("名刺電圧 ${status.vddMv}mV")
                        if (status.responseMillis > 0) {
                            if (isNotEmpty()) append("・")
                            append("応答 ${status.responseMillis}ms")
                        }
                        if (status.recentIssues > 0) {
                            if (isNotEmpty()) append("・")
                            append("直近の問題 ${status.recentIssues}回")
                        }
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ProgressStepItem(
    number: Int,
    label: String,
    iconRes: Int,
    active: Boolean,
    complete: Boolean,
) {
    val containerColor: Color
    val contentColor: Color
    when {
        active -> {
            containerColor = MaterialTheme.colorScheme.primary
            contentColor = MaterialTheme.colorScheme.onPrimary
        }
        complete -> {
            containerColor = MaterialTheme.colorScheme.primaryContainer
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer
        }
        else -> {
            containerColor = MaterialTheme.colorScheme.surfaceVariant
            contentColor = MaterialTheme.colorScheme.onSurfaceVariant
        }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            number.toString(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Surface(
            modifier = Modifier.size(44.dp),
            shape = CircleShape,
            color = containerColor,
            contentColor = contentColor,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    painter = painterResource(iconRes),
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = if (active || complete) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            textAlign = TextAlign.Center,
            maxLines = 1,
        )
    }
}

private data class ProgressStep(val label: String, val iconRes: Int)

private val progressSteps = listOf(
    ProgressStep("接続", R.drawable.ic_nfc),
    ProgressStep("転送", R.drawable.ic_upload_file),
    ProgressStep("更新", R.drawable.ic_sync),
    ProgressStep("完了", R.drawable.ic_check_circle),
)

private const val DATA_PROGRESS_START = 0.15f
private const val DATA_PROGRESS_END = 0.72f

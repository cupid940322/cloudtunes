package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog

// ── TV 输入支持 ──
// 电视上点输入框往往调不出系统输入法（很多盒子/电视根本没有 IME，或 Compose 输入框
// 拿不到软键盘焦点）。这里做统一封装：
//   手机 → 直接用原生 OutlinedTextField（行为不变）
//   TV   → 显示成可聚焦的输入行，按 OK 弹出内置屏幕键盘（字母/数字/符号齐全，不依赖输入法）

/// 当前是否跑在 TV 上（电视 UiMode，或 TV 版包名）
@Composable
fun isTvUi(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        val uiMode = context.getSystemService(android.app.UiModeManager::class.java)
        uiMode?.currentModeType == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION ||
            context.packageName.endsWith(".tv")
    }
}

@Composable
fun InputField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = true,
    minLines: Int = 1,
    placeholder: String? = null,
    textStyle: TextStyle? = null,
) {
    if (!isTvUi()) {
        val ph: (@Composable () -> Unit)? = if (placeholder != null) {
            { Text(placeholder, color = Color.White.copy(alpha = 0.35f), fontSize = 14.sp) }
        } else null
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = modifier,
            label = { Text(label) },
            singleLine = singleLine,
            minLines = minLines,
            placeholder = ph,
            textStyle = textStyle ?: LocalTextStyle.current,
        )
        return
    }

    // ── TV 版输入行 ──
    var showKeyboard by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()

    Box(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .background(if (focused) Color.White.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.05f))
            .border(
                if (focused) 2.dp else 1.dp,
                if (focused) Color(0xFFE85D5D) else Color.White.copy(alpha = 0.25f),
                RoundedCornerShape(10.dp),
            )
            .onKeyEvent { e ->
                if (e.type == KeyEventType.KeyDown &&
                    (e.key == Key.DirectionCenter || e.key == Key.Enter)
                ) {
                    showKeyboard = true
                    true
                } else false
            }
            .focusable(interactionSource = interaction)
            .clickable(interactionSource = interaction, indication = null) { showKeyboard = true }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Column {
            Text(label, color = Color.White.copy(alpha = 0.55f), fontSize = 12.sp)
            Spacer(Modifier.height(2.dp))
            Text(
                value.ifBlank { placeholder ?: "按「OK」输入" },
                color = if (value.isBlank()) Color.White.copy(alpha = 0.35f) else Color.White,
                fontSize = 16.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }

    if (showKeyboard) {
        TvKeyboardDialog(
            title = label,
            initial = value,
            onConfirm = {
                onValueChange(it)
                showKeyboard = false
            },
            onDismiss = { showKeyboard = false },
        )
    }
}

/// 内置屏幕键盘（遥控器方向键移动、OK 输入）
@Composable
fun TvKeyboardDialog(
    title: String,
    initial: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    var shift by remember { mutableStateOf(false) }
    var symbols by remember { mutableStateOf(false) }

    val letterRows = listOf("1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm")
    val symbolRows = listOf("-_=+:/\\|", "@.#%&*?!", "()[]{}<>", "\"'`,;~^$")

    Dialog(
        onDismissRequest = onDismiss,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            color = Color(0xFF1E1D24),
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth(0.9f).widthIn(max = 900.dp),
        ) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(title, color = Color.White, fontSize = 18.sp,
                    style = MaterialTheme.typography.titleMedium)

                // 当前输入内容
                Box(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.08f))
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                ) {
                    Text(
                        text.ifEmpty { "（空）" },
                        color = if (text.isEmpty()) Color.White.copy(alpha = 0.35f) else Color.White,
                        fontSize = 17.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // 键盘
                val rows = if (symbols) symbolRows else letterRows
                rows.forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        row.forEach { ch ->
                            val out = if (shift) ch.uppercaseChar() else ch
                            KeyCap(out.toString()) { text += out }
                        }
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    KeyCap("空格", weight = 2f) { text += " " }
                    KeyCap("←") { if (text.isNotEmpty()) text = text.dropLast(1) }
                    KeyCap(if (shift) "小写" else "大写") { shift = !shift }
                    KeyCap(if (symbols) "字母" else "符号") { symbols = !symbols }
                    KeyCap("清空") { text = "" }
                }

                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                ) {
                    OutlinedButton(onClick = onDismiss) { Text("取消") }
                    Button(onClick = { onConfirm(text) }) { Text("确定") }
                }
            }
        }
    }
}

@Composable
private fun RowScope.KeyCap(label: String, weight: Float = 1f, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Box(
        Modifier
            .weight(weight)
            .height(48.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (focused) Color(0xFFE85D5D) else Color.White.copy(alpha = 0.10f))
            .onKeyEvent { e ->
                if (e.type == KeyEventType.KeyDown &&
                    (e.key == Key.DirectionCenter || e.key == Key.Enter)
                ) {
                    onClick()
                    true
                } else false
            }
            .focusable(interactionSource = interaction)
            .clickable(interactionSource = interaction, indication = null) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (focused) Color.White else Color.White.copy(alpha = 0.85f),
            fontSize = 16.sp,
        )
    }
}

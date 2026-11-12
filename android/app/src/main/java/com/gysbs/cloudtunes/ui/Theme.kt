package com.gysbs.cloudtunes.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

object Theme {
    @Composable
    fun CloudTunesTheme(content: @Composable () -> Unit) {
        val dark = isSystemInDarkTheme()
        MaterialTheme(
            colorScheme = if (dark) darkColorScheme() else lightColorScheme(),
            content = content,
        )
    }
}

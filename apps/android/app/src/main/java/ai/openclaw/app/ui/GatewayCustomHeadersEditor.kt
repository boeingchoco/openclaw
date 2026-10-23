package ai.openclaw.app.ui

import ai.openclaw.app.gateway.GatewayCustomHeaders
import ai.openclaw.app.i18n.nativeString
import ai.openclaw.app.ui.design.ClawPlainIconButton
import ai.openclaw.app.ui.design.ClawSecondaryButton
import ai.openclaw.app.ui.design.ClawTextField
import ai.openclaw.app.ui.design.ClawTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Proxy headers typed into one manual-connect form, such as Cloudflare Access service tokens.
 * Values are credentials: hosts keep this in plain `remember`, never saved instance state, and
 * values are never shown again. The form owns it so a typed but unadded header still connects.
 */
@Stable
internal class GatewayCustomHeadersInput {
  var headers by mutableStateOf(emptyMap<String, String>())
    private set
  var name by mutableStateOf("")
  var value by mutableStateOf("")

  val rejection: GatewayCustomHeaders.Rejection?
    get() = if (name.isBlank()) null else GatewayCustomHeaders.rejection(name, value)

  val canAdd: Boolean
    get() = name.isNotBlank() && value.isNotBlank() && rejection == null

  fun add() {
    if (!canAdd) return
    val trimmed = name.trim()
    // Header names are case-insensitive; adding one again replaces its value.
    headers = headers.filterKeys { !it.equals(trimmed, ignoreCase = true) } + (trimmed to value)
    name = ""
    value = ""
  }

  fun remove(headerName: String) {
    headers = headers - headerName
  }

  fun clear() {
    headers = emptyMap()
    name = ""
    value = ""
  }

  /** Headers to connect with, including a complete draft the user did not add yet. */
  fun forConnect(): Map<String, String> {
    add()
    return headers
  }
}

/** Editor for [GatewayCustomHeadersInput]; hosts show it only for secure manual endpoints. */
@Composable
internal fun GatewayCustomHeadersEditor(
  input: GatewayCustomHeadersInput,
  modifier: Modifier = Modifier,
) {
  Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(text = nativeString("Custom headers (optional)"), style = ClawTheme.type.caption, color = ClawTheme.colors.textMuted)
    Text(
      text = nativeString("Sent only over secure connections to this gateway, for example Cloudflare Access service token headers. Saved headers stay; adding one with the same name replaces it."),
      style = ClawTheme.type.caption,
      color = ClawTheme.colors.textMuted,
    )
    for (headerName in input.headers.keys) {
      Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text = headerName, style = ClawTheme.type.mono, color = ClawTheme.colors.text, modifier = Modifier.weight(1f))
        ClawPlainIconButton(
          icon = Icons.Default.Close,
          contentDescription = nativeString("Remove header \$name", headerName),
          onClick = { input.remove(headerName) },
        )
      }
    }
    ClawTextField(value = input.name, onValueChange = { input.name = it }, placeholder = "", label = nativeString("Header name"))
    ClawTextField(value = input.value, onValueChange = { input.value = it }, placeholder = "", label = nativeString("Header value"), secret = true)
    input.rejection?.let {
      Text(text = it.message(), style = ClawTheme.type.caption, color = ClawTheme.colors.warning)
    }
    ClawSecondaryButton(
      text = nativeString("Add header"),
      enabled = input.canAdd,
      onClick = input::add,
      modifier = Modifier.fillMaxWidth(),
    )
  }
}

private fun GatewayCustomHeaders.Rejection.message(): String =
  when (this) {
    GatewayCustomHeaders.Rejection.INVALID_NAME -> nativeString("Enter a valid header name, such as CF-Access-Client-Id.")
    GatewayCustomHeaders.Rejection.RESERVED_NAME -> nativeString("This header is set by the connection itself.")
    GatewayCustomHeaders.Rejection.INVALID_VALUE -> nativeString("Header values must be printable ASCII on one line, without tabs.")
  }

// ignore: deprecated_member_use
import 'dart:html' as html;

/// Web platform helpers for the Discord OAuth redirect flow.
void discordOpenUrl(String url) {
  html.window.location.assign(url);
}

/// Returns the `code` param from the current browser URL (after a Discord
/// OAuth redirect), or null when this is not a redirect callback.
String? discordExtractAuthCode() {
  final params = Uri.parse(html.window.location.href).queryParameters;
  return params['code'];
}

/// Returns the `state` param from the OAuth redirect, for CSRF validation.
String? discordExtractAuthState() {
  final params = Uri.parse(html.window.location.href).queryParameters;
  return params['state'];
}

/// Removes the OAuth parameters (`code`, `state`, `iss`, `error`, …) from the
/// address bar and history so a page refresh cannot replay the same
/// authorization code and the URL stays clean.
void discordClearRedirectQuery() {
  final uri = Uri.parse(html.window.location.href);
  final cleanParams = Map<String, String>.from(uri.queryParameters)
    ..remove('code')
    ..remove('state')
    ..remove('iss')
    ..remove('error')
    ..remove('error_description');
  final cleanUri = uri.replace(queryParameters: cleanParams);
  html.window.history.replaceState(null, '', cleanUri.toString());
}

/// Returns the address bar to a clean path (e.g. "/") after the OAuth
/// callback finished, so the callback URL is not left behind.
void discordResetUrl(String path) {
  try {
    html.window.history.replaceState(null, '', path);
  } catch (_) {
    // Ignore — the app still works, only the URL stays as it is.
  }
}

// ignore: deprecated_member_use
import 'dart:html' as html;

/// Nilai kecil di localStorage (web).
String readLocalValue(String key) => html.window.localStorage[key] ?? '';

void writeLocalValue(String key, String value) {
  try {
    html.window.localStorage[key] = value;
  } catch (_) {
    // Mode privat / storage diblokir — abaikan.
  }
}

/// Muat ulang halaman supaya bundle terbaru langsung dipakai.
void reloadApp() => html.window.location.reload();

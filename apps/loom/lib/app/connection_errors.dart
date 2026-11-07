import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'loom_strings.dart';

/// Stable codes for connection-class failures stored in controller
/// `errorMessage` fields. Raw exceptions (`HandshakeException: Handshake error
/// in client (…certificate unknown)`) leak transport jargon with no recovery
/// path; screens translate these codes into short, actionable, bilingual text.
const loomTlsHandshakeCode = 'tls_handshake';
const loomNetworkUnreachableCode = 'network_unreachable';
const loomTimeoutCode = 'connection_timeout';

/// Classifies a caught error into one of the connection codes above, or null
/// when it is not a connection-class failure.
String? loomConnectionErrorCode(Object error) {
  final text = error.toString();
  if (error is HandshakeException ||
      text.contains('HandshakeException') ||
      text.contains('handshake error')) {
    return loomTlsHandshakeCode;
  }
  if (error is TimeoutException ||
      text.contains('TimeoutException') ||
      text.contains('timed out')) {
    return loomTimeoutCode;
  }
  if (error is SocketException ||
      text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Connection reset') ||
      text.contains('Network is unreachable')) {
    return loomNetworkUnreachableCode;
  }
  return null;
}

/// Truncates any error into a single storable line.
String loomSafeErrorText(Object error) {
  final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
  return text.length <= 240 ? text : text.substring(0, 240);
}

/// Translates a stored `errorMessage` (which may be a connection code) into
/// friendly bilingual text. Unknown strings pass through untouched.
String loomConnectionErrorLabel(BuildContext context, String stored) {
  switch (stored) {
    case loomTlsHandshakeCode:
      return tr(
        context,
        "This device doesn't trust this server's security certificate yet. "
        'Import the certificate file the server admin gave you '
        '(“Trust local HTTPS certificate”), or double-check the address — '
        'it must match the address the certificate was issued for.',
        'این گوشی هنوز به گواهی امنیتی این سرور اعتماد ندارد. '
        'فایل گواهی را که مدیر سرور به شما داده وارد کنید '
        '(«اعتماد به گواهی HTTPS محلی») یا نشانی را دقیق بررسی کنید — '
        'باید با همان نشانی‌ای که گواهی برایش صادر شده یکسان باشد.',
      );
    case loomNetworkUnreachableCode:
      return tr(
        context,
        "Couldn't reach this server. Check your internet connection and the "
        'server address, then try again.',
        'اتصال به این سرور برقرار نشد. اینترنت و نشانی سرور را بررسی کنید و '
        'دوباره تلاش کنید.',
      );
    case loomTimeoutCode:
      return tr(
        context,
        'The server took too long to respond. Try again in a moment.',
        'سرور دیر پاسخ داد. کمی بعد دوباره تلاش کنید.',
      );
    default:
      return stored;
  }
}

/// Whether a stored error is a TLS trust failure, so screens can offer the
/// certificate-import action right where the error appears.
bool loomIsTlsHandshake(String stored) => stored == loomTlsHandshakeCode;

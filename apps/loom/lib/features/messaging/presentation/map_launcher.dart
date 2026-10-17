import 'package:loom_design/loom_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../app/loom_strings.dart';

const loomMapsChannel = MethodChannel('loom/maps');

/// Explicit user action only. Android's resolver offers every installed geo
/// handler, including local map apps, rather than binding the pin to Google.
Future<void> openLoomMaps(
  BuildContext context,
  double lat,
  double lon,
) async {
  if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
    throw ArgumentError('Invalid coordinates');
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      if (await loomMapsChannel.invokeMethod<bool>('choose', {
            'lat': lat,
            'lon': lon,
            'title': tr(context, 'Open in maps', 'باز کردن در نقشه‌ها'),
          }) ==
          true) {
        return;
      }
    } on MissingPluginException {
      /* Desktop/widget fallback. */
    } on PlatformException {
      /* Offer browser maps if no handler can launch. */
    }
  }
  if (!context.mounted) return;
  final choices = <(String, Uri)>[];
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    for (final option in [
      ('Apple Maps', Uri.parse('maps://?ll=$lat,$lon&q=$lat,$lon')),
      ('Google Maps', Uri.parse('comgooglemaps://?q=$lat,$lon')),
      ('Waze', Uri.parse('waze://?ll=$lat,$lon&navigate=yes')),
      ('Neshan', Uri.parse('neshan://?destination=$lat,$lon')),
    ]) {
      if (await canLaunchUrl(option.$2)) choices.add(option);
    }
  }
  if (!context.mounted) return;
  choices.addAll([
    (
      'OpenStreetMap',
      Uri.https('www.openstreetmap.org', '/', {
        'mlat': '$lat',
        'mlon': '$lon',
      }).replace(fragment: 'map=16/$lat/$lon'),
    ),
    (
      'Google Maps',
      Uri.https('www.google.com', '/maps/search/', {
        'api': '1',
        'query': '$lat,$lon',
      }),
    ),
  ]);
  final selected = await showLoomActionSheet<Uri>(
    context: context,
    title: tr(context, 'Open in maps', 'باز کردن در نقشه‌ها'),
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final choice in choices)
          ListTile(
            leading: const Icon(LoomIcons.map_outlined),
            title: Text(choice.$1),
            subtitle: choice.$2.scheme == 'https'
                ? Text(tr(context, 'Browser map', 'نقشه در مرورگر'))
                : null,
            onTap: () => Navigator.pop(context, choice.$2),
          ),
      ],
    ),
  );
  if (selected != null &&
      !await launchUrl(selected, mode: LaunchMode.externalApplication)) {
    throw StateError('No maps handler');
  }
}

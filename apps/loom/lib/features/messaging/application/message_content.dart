import 'dart:convert';

/// This entire document travels INSIDE the authenticated E2EE plaintext. Never
/// copy quote text, attachment keys, URLs or coordinates into record metadata.
class LoomMessageContent {
  const LoomMessageContent({
    this.text = '',
    this.reply,
    this.attachment,
    this.location,
  });
  static const prefix = '\u2063loom.content.v1:';
  final String text;
  final Map<String, Object?>? reply;
  final Map<String, Object?>? attachment;
  final Map<String, Object?>? location;
  String get replyExcerpt {
    if (text.trim().isNotEmpty) return text;
    final media = attachment;
    if (media != null) {
      return switch (media['kind']) {
        'image' => 'Photo',
        'video' => 'Video',
        'video_note' => 'Video message',
        'audio' =>
          media['music'] == true
              ? (media['name'] as String? ?? 'Audio file')
              : 'Voice message',
        'file' => media['name'] as String? ?? 'File',
        _ => 'Attachment',
      };
    }
    return location != null ? 'Location' : '';
  }

  /// A missing or empty local original must never erase an authenticated quote.
  String? resolvedReplyExcerpt(String? localOriginal) {
    if (localOriginal?.trim().isNotEmpty == true) return localOriginal;
    final excerpt = reply?['text'];
    return excerpt is String && excerpt.trim().isNotEmpty ? excerpt : null;
  }

  String get preview => text.isNotEmpty
      ? text
      : attachment != null
      ? (attachment!['kind'] == 'image'
            ? '📷'
            : attachment!['kind'] == 'audio'
            ? '🎤'
            : attachment!['kind'] == 'file'
            ? '📎'
            : '🎬')
      : location != null
      ? '📍'
      : '';
  String encode() =>
      '$prefix${jsonEncode({'v': 1, 'text': text, if (reply != null) 'reply': reply, if (attachment != null) 'attachment': attachment, if (location != null) 'location': location})}';
  static LoomMessageContent decode(String value) {
    if (!value.startsWith(prefix)) {
      return LoomMessageContent(text: value);
    }
    final data = jsonDecode(value.substring(prefix.length));
    if (data is! Map<String, dynamic> ||
        data['v'] != 1 ||
        data['text'] is! String) {
      throw const FormatException('Invalid encrypted message content');
    }
    Map<String, Object?>? field(String name) {
      final entry = data[name];
      if (entry == null) {
        return null;
      }
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Invalid content field');
      }
      return Map<String, Object?>.from(entry);
    }

    final quote = field('reply');
    if (quote != null &&
        (quote['clientId'] is! String ||
            quote['text'] is! String ||
            (quote['text'] as String).length > 1024 ||
            quote['sender'] is! String)) {
      throw const FormatException('Invalid reply');
    }
    final media = field('attachment');
    if (media != null &&
        (!const [
              'image',
              'video',
              'audio',
              'video_note',
              'file',
            ].contains(media['kind']) ||
            media['url'] is! String ||
            media['key'] is! String ||
            media['bytes'] is! int ||
            (media['bytes'] as int) < 1 ||
            (media['bytes'] as int) > 128 * 1024 * 1024)) {
      throw const FormatException('Invalid media');
    }
    if (media != null) {
      for (final field in ['width', 'height']) {
        final value = media[field];
        if (value != null && (value is! int || value < 1 || value > 60000)) {
          throw const FormatException('Invalid media dimensions');
        }
      }
      if ((media['animated'] != null && media['animated'] is! bool) ||
          (media['mime'] != null &&
              !const [
                'image/gif',
                'image/webp',
                'image/png',
                'image/jpeg',
              ].contains(media['mime'])) ||
          (media['sticker'] != null &&
              (media['sticker'] is! bool || media['kind'] != 'image'))) {
        throw const FormatException('Invalid animated image metadata');
      }
      final name = media['name'],
          music = media['music'],
          peaks = media['waveform'],
          duration = media['durationMs'];
      if ((duration != null &&
              (duration is! int ||
                  duration <= 0 ||
                  duration > 24 * 60 * 60 * 1000)) ||
          (name != null && (name is! String || name.length > 200)) ||
          (music != null && music is! bool) ||
          (peaks != null &&
              (peaks is! List ||
                  peaks.length > 64 ||
                  peaks.any(
                    (v) => v is! num || !v.isFinite || v < 0 || v > 1,
                  )))) {
        throw const FormatException('Invalid audio metadata');
      }
    }
    final point = field('location');
    if (point != null) {
      final lat = point['lat'], lon = point['lon'];
      if (lat is! num ||
          lon is! num ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat.abs() > 90 ||
          lon.abs() > 180 ||
          point['at'] is! int) {
        throw const FormatException('Invalid location');
      }
      if (point['session'] != null &&
          (point['session'] is! String ||
              point['until'] is! int ||
              point['stopped'] is! bool ||
              (point['until'] as int) - (point['at'] as int) >
                  const Duration(hours: 1).inMilliseconds)) {
        throw const FormatException('Invalid live location');
      }
    }
    return LoomMessageContent(
      text: data['text'] as String,
      reply: quote == null ? null : _freezeMap(quote),
      attachment: media == null ? null : _freezeMap(media),
      location: point == null ? null : _freezeMap(point),
    );
  }

  static Map<String, Object?> _freezeMap(Map<String, Object?> map) =>
      Map<String, Object?>.unmodifiable(
        map.map((key, value) => MapEntry(key, _freeze(value))),
      );
  static Object? _freeze(Object? value) => switch (value) {
    Map<String, dynamic> map => _freezeMap(map),
    List list => List<Object?>.unmodifiable(list.map(_freeze)),
    _ => value,
  };
}

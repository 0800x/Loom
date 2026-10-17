import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import '../application/group_photo.dart';

Future<Uint8List?> pickLoomGroupPhoto() async {
  final mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final XFile? file = mobile
      ? await ImagePicker().pickImage(source: ImageSource.gallery)
      : await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'Images',
              extensions: ['png', 'jpg', 'jpeg', 'webp'],
              mimeTypes: ['image/*'],
            ),
          ],
        );
  if (file == null) return null;
  if (await file.length() > 8 * 1024 * 1024) {
    throw const FormatException('Photo too large');
  }
  final bytes = await file.readAsBytes();
  try {
    return await normalizeGroupPhoto(bytes);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

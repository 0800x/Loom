import 'package:camera/camera.dart';
import 'package:loom_next/features/media/application/video_note_camera_selection.dart';
import 'package:flutter_test/flutter_test.dart';

const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);
const rear = CameraDescription(
  name: 'rear',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

void main() {
  test('starts with the front camera and offers a rear-camera retake', () {
    final selection = LoomVideoNoteCameraSelection();
    expect(selection.updateDevices([rear, front]), front);
    expect(selection.alternateLens, CameraLensDirection.back);
  });

  test('a new take uses the explicit preference and can switch back', () {
    final selection = LoomVideoNoteCameraSelection();
    selection.updateDevices([front, rear]);
    selection.preferredLens = CameraLensDirection.back;
    expect(selection.updateDevices([front, rear]), rear);
    expect(selection.alternateLens, CameraLensDirection.front);
  });

  test('one-camera devices have no switch action', () {
    final selection = LoomVideoNoteCameraSelection();
    expect(selection.updateDevices([rear]), rear);
    expect(selection.alternateLens, isNull);
  });

  test(
    'removed cameras fall back safely and empty devices clear the action',
    () {
      final selection = LoomVideoNoteCameraSelection();
      selection.preferredLens = CameraLensDirection.back;
      expect(selection.updateDevices([front]), front);
      expect(selection.alternateLens, isNull);
      expect(selection.updateDevices([]), isNull);
      expect(selection.alternateLens, isNull);
    },
  );
}

import 'package:camera/camera.dart';

/// Chooses a physical lens for a new take. An active recording is never
/// switched; changing this preference is applied after the draft is discarded.
class LoomVideoNoteCameraSelection {
  CameraLensDirection preferredLens = CameraLensDirection.front;
  List<CameraDescription> _devices = const [];
  CameraLensDirection? _selectedLens;

  CameraDescription? updateDevices(List<CameraDescription> devices) {
    _devices = List.unmodifiable(devices);
    if (_devices.isEmpty) {
      _selectedLens = null;
      return null;
    }
    final preferred = _devices.where((c) => c.lensDirection == preferredLens);
    final selected = preferred.isEmpty ? _devices.first : preferred.first;
    _selectedLens = selected.lensDirection;
    return selected;
  }

  CameraLensDirection? get alternateLens {
    for (final lens in [CameraLensDirection.front, CameraLensDirection.back]) {
      if (lens != _selectedLens &&
          _devices.any((camera) => camera.lensDirection == lens)) {
        return lens;
      }
    }
    return null;
  }
}

import 'dart:typed_data';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../application/groups_controller.dart';

class LoomGroupAvatar extends StatelessWidget {
  const LoomGroupAvatar({
    required this.groupId,
    required this.label,
    this.size = LoomSizing.avatar,
    this.groups,
    super.key,
  });
  final String groupId, label;
  final double size;
  final LoomGroupsController? groups;
  @override
  Widget build(BuildContext context) {
    final controller = groups ?? LoomGroupsScope.maybeOf(context);
    if (controller == null) return LoomAvatar(label: label, size: size);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => LoomGroupPhotoAvatar(
        label: label,
        size: size,
        photo: controller.groupPhoto(groupId),
      ),
    );
  }
}

class LoomGroupPhotoAvatar extends StatelessWidget {
  const LoomGroupPhotoAvatar({
    required this.label,
    required this.size,
    this.photo,
    super.key,
  });
  final String label;
  final double size;
  final Uint8List? photo;
  @override
  Widget build(BuildContext context) => photo == null
      ? LoomAvatar(label: label, size: size)
      : SizedBox.square(
          dimension: size,
          child: ClipOval(
            child: Image.memory(
              photo!,
              semanticLabel: label,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => LoomAvatar(label: label, size: size),
            ),
          ),
        );
}

import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../application/local_avatar_store.dart';

const loomAvatarColors = <Color>[
  Color(0xff487ed1),
  Color(0xff9970c4),
  Color(0xff318c82),
  Color(0xffbb665d),
  Color(0xffac7935),
  Color(0xff537d92),
];

/// Shared by the profile, settings card and Chats header.
class LoomOwnAvatar extends StatefulWidget {
  const LoomOwnAvatar({
    required this.name,
    this.identityId,
    this.size = 48,
    super.key,
  });
  final String name;
  final String? identityId;
  final double size;
  @override
  State<LoomOwnAvatar> createState() => _LoomOwnAvatarState();
}

class _LoomOwnAvatarState extends State<LoomOwnAvatar> {
  LoomLocalAvatarStore? _store;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(LoomOwnAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityId != widget.identityId) _bind();
  }

  void _bind() {
    _store?.removeListener(_changed);
    final id = widget.identityId;
    _store = id == null ? null : LoomLocalAvatarStore.forIdentity(id);
    _store?.addListener(_changed);
    if (_store != null) unawaited(_store!.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = loomAvatarColors[_store?.colorIndex ?? 0];
    final photo = _store?.photo;
    final initials = widget.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part.characters.first.toUpperCase())
        .join();
    final monogram = Center(
      child: Text(
        initials.isEmpty ? '?' : initials,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: widget.size * .34,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.loom.border, width: 1.5),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(color, Colors.white, .12)!,
                Color.lerp(color, Colors.black, .17)!,
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: ClipOval(
              child: AnimatedSwitcher(
                duration: LoomAccessibility.fromContext(context).reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                child: photo == null
                    ? KeyedSubtree(
                        key: ValueKey('initials-${_store?.colorIndex}'),
                        child: monogram,
                      )
                    : Image.memory(
                        photo,
                        key: ObjectKey(photo),
                        width: widget.size,
                        height: widget.size,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => monogram,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

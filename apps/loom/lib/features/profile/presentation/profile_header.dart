import 'dart:async';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../../../app/loom_strings.dart';
import '../application/local_avatar_store.dart';
import 'own_avatar.dart';

/// Pull past the top edge or tap the avatar to expand its photo. A pinned title
/// replaces the large hero when scrolling through account details.
class LoomProfileHeader extends StatefulWidget {
  const LoomProfileHeader({required this.name, this.identityId, super.key});
  final String name;
  final String? identityId;
  @override
  State<LoomProfileHeader> createState() => _LoomProfileHeaderState();
}

class _LoomProfileHeaderState extends State<LoomProfileHeader> {
  LoomLocalAvatarStore? _store;
  bool _viewing = false;
  bool _expanded = false;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant LoomProfileHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityId != widget.identityId) {
      _bind();
    }
  }

  void _bind() {
    _store?.removeListener(_changed);
    _store = widget.identityId == null
        ? null
        : LoomLocalAvatarStore.forIdentity(widget.identityId!);
    _store?.addListener(_changed);
    if (_store != null) {
      unawaited(_store!.load());
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _store?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _viewPhoto() async {
    if (_viewing || !mounted) {
      return;
    }
    _viewing = true;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: LoomGlassAppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(widget.name),
            ),
            body: Center(
              child: _store?.photo == null
                  ? LoomOwnAvatar(
                      name: widget.name,
                      identityId: widget.identityId,
                      size: 260,
                    )
                  : InteractiveViewer(
                      minScale: .8,
                      maxScale: 5,
                      child: Image.memory(_store!.photo!, fit: BoxFit.contain),
                    ),
            ),
          ),
        ),
      );
    } finally {
      _viewing = false;
    }
  }

  Future<void> _expand() async {
    // Sliver stretch callbacks run during layout. Wait for that frame to finish
    // before changing the header extent; taps also use this safe path.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = _store?.photo;
    final cover = _expanded && photo != null;
    final compactHeight =
        300.0 +
        (MediaQuery.textScalerOf(context).scale(28) - 28).clamp(0.0, 28.0) * 3;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: _expanded
          ? (MediaQuery.sizeOf(context).height * .72).clamp(
              compactHeight + 20,
              720.0,
            )
          : compactHeight,
      stretchTriggerOffset: 90,
      onStretchTrigger: _expand,
      backgroundColor: context.loom.background,
      surfaceTintColor: Colors.transparent,
      title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (_expanded)
          IconButton(
            tooltip: tr(context, 'Collapse photo', 'جمع کردن عکس'),
            onPressed: () => setState(() => _expanded = false),
            icon: const Icon(LoomIcons.close_fullscreen_rounded),
          ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: Material(
          color: context.loom.surface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover) ...[
                Image.memory(photo, fit: BoxFit.cover),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        context.loom.background.withValues(alpha: .6),
                        Colors.transparent,
                        Colors.black.withValues(alpha: .8),
                      ],
                      stops: const [0, .45, 1],
                    ),
                  ),
                ),
              ],
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: cover
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.center,
                    children: [
                      if (!cover)
                        Tooltip(
                          message: tr(
                            context,
                            'Expand profile photo',
                            'گسترش عکس پروفایل',
                          ),
                          child: InkWell(
                            onTap: _expanded ? _viewPhoto : _expand,
                            customBorder: const CircleBorder(),
                            child: LoomOwnAvatar(
                              name: widget.name,
                              identityId: widget.identityId,
                              size: _expanded ? 180 : 132,
                            ),
                          ),
                        )
                      else
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: IconButton(
                            tooltip: tr(context, 'View photo', 'نمایش عکس'),
                            onPressed: _viewPhoto,
                            icon: const Icon(
                              LoomIcons.fullscreen_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      const SizedBox(height: 18),
                      Text(
                        widget.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: cover ? TextAlign.start : TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: cover ? Colors.white : null,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(context, 'Loom profile', 'پروفایل لوم'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cover
                              ? Colors.white70
                              : context.loom.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


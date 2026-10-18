import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, TapGestureRecognizer;
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../loom_icons.dart';
import '../loom_chat_layout.dart';
import '../loom_accessibility.dart';
import '../loom_interactions.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';
import 'loom_component_models.dart';
import 'loom_identity.dart';
import 'loom_links.dart';

class LoomChatRow extends StatelessWidget {
  const LoomChatRow({
    required this.name,
    required this.preview,
    required this.time,
    this.unread = 0,
    this.presence = false,
    this.avatar,
    this.selected = false,
    this.muted = false,
    this.pinned = false,
    this.draft = false,
    this.typing = false,
    this.delivery = LoomDeliveryState.none,
    required this.draftLabel,
    required this.typingLabel,
    this.onTap,
    super.key,
  });

  final String name;
  final String preview;
  final String time;
  final int unread;
  final bool presence;
  final Widget? avatar;
  final bool selected;
  final bool muted;
  final bool pinned;
  final bool draft;
  final bool typing;
  final LoomDeliveryState delivery;
  final String draftLabel;
  final String typingLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final previewColor = typing ? p.connectivity : p.textSecondary;
    final radius = BorderRadius.circular(LoomRadii.control);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoomSpacing.xxs / 2),
      child: Semantics(
        selected: selected,
        child: LoomPressable(
          enabled: onTap != null,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: AnimatedContainer(
              duration: LoomAccessibility.fromContext(context).reduceMotion
                  ? Duration.zero
                  : LoomMotion.component,
              constraints: const BoxConstraints(
                minHeight: LoomSizing.compactRowHeight,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: LoomSpacing.sm,
                vertical: LoomSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: selected ? p.surfaceElevated : Colors.transparent,
                borderRadius: radius,
                border: Border.all(
                  color: selected ? p.borderStrong : Colors.transparent,
                  width: LoomBorders.hairline,
                ),
              ),
              child: Row(
                children: [
                  avatar ?? LoomAvatar(label: name, presence: presence),
                  const SizedBox(width: LoomSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (pinned) ...[
                              Icon(
                                LoomIcons.push_pin_outlined,
                                size: LoomIconSize.micro,
                                color: p.textMuted,
                              ),
                              const SizedBox(width: LoomSpacing.xxs),
                            ],
                            Text(
                              time,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: p.textMuted),
                            ),
                          ],
                        ),
                        const SizedBox(height: LoomSpacing.xxs),
                        Row(
                          children: [
                            if (delivery != LoomDeliveryState.none) ...[
                              _DeliveryIcon(state: delivery),
                              const SizedBox(width: LoomSpacing.xxs),
                            ],
                            if (draft) ...[
                              Text(
                                draftLabel,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: p.critical,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(width: LoomSpacing.xxs),
                            ],
                            Expanded(
                              child: Text(
                                typing ? typingLabel : preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: previewColor),
                              ),
                            ),
                            if (muted) ...[
                              const SizedBox(width: LoomSpacing.xs),
                              Icon(
                                LoomIcons.volume_off_outlined,
                                size: LoomIconSize.compact,
                                color: p.textMuted,
                              ),
                            ],
                            if (unread > 0) ...[
                              const SizedBox(width: LoomSpacing.xs),
                              Container(
                                constraints: const BoxConstraints(
                                  minWidth: LoomIconSize.standard,
                                  minHeight: LoomIconSize.standard,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: LoomSpacing.xs,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: muted ? p.surfaceMuted : p.primary,
                                  borderRadius: BorderRadius.circular(
                                    LoomRadii.pill,
                                  ),
                                ),
                                child: Text(
                                  unread > 99 ? '99+' : '$unread',
                                  style: TextStyle(
                                    color:
                                        muted ? p.textSecondary : p.onPrimary,
                                    fontSize: LoomTypeScale.labelSmall,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeliveryIcon extends StatelessWidget {
  const _DeliveryIcon({required this.state, this.neutral});
  final Color? neutral;

  final LoomDeliveryState state;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final icon = switch (state) {
      LoomDeliveryState.queued => LoomIcons.schedule_rounded,
      LoomDeliveryState.sending => LoomIcons.sync_rounded,
      LoomDeliveryState.sent => LoomIcons.check_rounded,
      LoomDeliveryState.delivered ||
      LoomDeliveryState.read =>
        LoomIcons.done_all_rounded,
      LoomDeliveryState.failed => LoomIcons.error_outline_rounded,
      LoomDeliveryState.none => LoomIcons.check_rounded,
    };
    final color = switch (state) {
      LoomDeliveryState.read => p.info,
      LoomDeliveryState.failed => p.critical,
      _ => neutral ?? p.textMuted,
    };
    return Icon(icon, size: LoomIconSize.compact, color: color);
  }
}

enum LoomMessagePresentation {
  sticker,
  text,
  voice,
  photo,
  video,
  roundVideo,
  location,
  liveLocation,
}

class LoomMessageBubble extends StatelessWidget {
  const LoomMessageBubble({
    required this.text,
    required this.time,
    required this.mine,
    this.delivery = LoomDeliveryState.none,
    this.deliveryLabel = '',
    this.transportLabel,
    this.onActions,
    this.onReply,
    this.replyLabel = 'Reply',
    this.quotedText,
    this.quotedAuthor,
    this.content,
    this.presentation = LoomMessagePresentation.text,
    this.onQuoteTap,
    this.onLinkTap,
    this.grouped = false,
    this.highlighted = false,
    super.key,
  });

  final VoidCallback? onQuoteTap;
  final ValueChanged<Uri>? onLinkTap;
  final bool grouped, highlighted;
  final String text;
  final String time;
  final bool mine;
  final LoomDeliveryState delivery;
  final String deliveryLabel;
  final String? transportLabel;
  final VoidCallback? onActions;
  final VoidCallback? onReply;
  final String replyLabel;
  final String? quotedText;
  final String? quotedAuthor;
  final Widget? content;
  final LoomMessagePresentation presentation;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, bounds) {
          final p = context.loom;
          final compact =
              LoomChatLayoutScope.of(context) == LoomChatDensity.compact;
          final receipt = mine && delivery != LoomDeliveryState.none
              ? _MessageDeliveryPresentation(
                  time: time,
                  state: delivery,
                  semanticLabel: deliveryLabel,
                )
              : mine
                  ? _deliveryPresentation(time)
                  : null;
          final sticker = presentation == LoomMessagePresentation.sticker;
          final round = presentation == LoomMessagePresentation.roundVideo;
          final framed = presentation == LoomMessagePresentation.photo ||
              presentation == LoomMessagePresentation.video ||
              presentation == LoomMessagePresentation.location;
          final overlay =
              (framed || round) && text.isEmpty && quotedText == null;
          final foreground = sticker
              ? p.textPrimary
              : overlay || round
                  ? Colors.white
                  : p.textPrimary;
          final secondary = foreground.withValues(alpha: .85);
          final maxWidth = (bounds.maxWidth * .86)
              .clamp(
                0.0,
                presentation == LoomMessagePresentation.voice
                    ? 260.0
                    : LoomSizing.messageMax,
              )
              .toDouble();
          final radius = BorderRadius.only(
            topLeft: Radius.circular(grouped && !mine ? 6 : 20),
            topRight: Radius.circular(grouped && mine ? 6 : 20),
            bottomLeft: Radius.circular(mine ? 20 : 6),
            bottomRight: Radius.circular(mine ? 6 : 20),
          );
          final metadata = Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              if (transportLabel != null)
                Tooltip(
                  message: transportLabel!,
                  child: Icon(
                    LoomIcons.wifi_tethering_rounded,
                    size: 12,
                    color: secondary,
                  ),
                ),
              Text(
                receipt?.time ?? time,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: secondary),
              ),
              if (receipt != null)
                Tooltip(
                  message: receipt.semanticLabel,
                  child: Semantics(
                    label: receipt.semanticLabel,
                    child: ExcludeSemantics(
                      child: _DeliveryIcon(
                        state: receipt.state,
                        neutral: secondary,
                      ),
                    ),
                  ),
                ),
              if (receipt != null &&
                  (receipt.state == LoomDeliveryState.queued ||
                      receipt.state == LoomDeliveryState.failed))
                Text(
                  receipt.semanticLabel,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: secondary),
                ),
            ],
          );
          final quote = quotedText == null
              ? null
              : InkWell(
                  onTap: onQuoteTap,
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (mine ? p.textPrimary : p.primary).withValues(
                        alpha: .12,
                      ),
                      borderRadius: BorderRadius.circular(10),
                      border: BorderDirectional(
                        start: BorderSide(
                          color: mine ? p.textPrimary : p.primary,
                          width: 3,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (quotedAuthor != null)
                          Text(
                            quotedAuthor!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: mine ? p.textPrimary : p.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        Text(
                          quotedText!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: p.textPrimary),
                        ),
                      ],
                    ),
                  ),
                );
          final messageText = _LinkedMessageText(
            text: text,
            onLinkTap: onLinkTap,
            selectable: onActions == null && onReply == null,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: p.textPrimary),
          );
          Widget body;
          if (content == null) {
            body = Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (quote != null) quote,
                if (text.isNotEmpty) messageText,
                metadata,
              ],
            );
          } else {
            final contentWidth = maxWidth
                .clamp(
                  0.0,
                  sticker
                      ? 180.0
                      : round
                          ? 240.0
                          : 340.0,
                )
                .toDouble();
            body = SizedBox(
              width: contentWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (quote != null)
                    Padding(padding: const EdgeInsets.all(8), child: quote),
                  if (overlay)
                    Stack(
                      children: [
                        content!,
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: round ? 12 : 8,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .5),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: metadata,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    content!,
                  if (text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 7, 10, 0),
                      child: messageText,
                    ),
                  if (!overlay)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 2, 10, 5),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: metadata,
                      ),
                    ),
                ],
              ),
            );
          }
          return Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Semantics(
              customSemanticsActions: onReply == null
                  ? null
                  : {CustomSemanticsAction(label: replyLabel): onReply!},
              child: LoomSwipeToReply(
                onReply: onReply,
                child: GestureDetector(
                  onLongPress: onActions,
                  onSecondaryTap: onActions,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: maxWidth,
                      minHeight: onActions != null || onReply != null ? 48 : 0,
                    ),
                    margin: EdgeInsets.only(
                      top: grouped
                          ? 2
                          : compact
                              ? 3
                              : 7,
                      bottom: 2,
                    ),
                    padding: content == null
                        ? EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: compact ? 6 : 8,
                          )
                        : presentation == LoomMessagePresentation.voice
                            ? const EdgeInsets.fromLTRB(10, 6, 6, 0)
                            : EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: round || sticker
                          ? Colors.transparent
                          : mine
                              ? Color.alphaBlend(
                                  p.primary.withValues(alpha: .16),
                                  p.surfaceElevated,
                                )
                              : p.surfaceElevated,
                      borderRadius: radius,
                      border: highlighted
                          ? Border.all(color: p.info, width: 2)
                          : null,
                    ),
                    clipBehavior: round || sticker ? Clip.none : Clip.antiAlias,
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: foreground),
                      child: IconTheme.merge(
                        data: IconThemeData(color: foreground),
                        child: body,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}

final class _MessageDeliveryPresentation {
  const _MessageDeliveryPresentation({
    required this.time,
    required this.state,
    required this.semanticLabel,
  });

  final String time;
  final LoomDeliveryState state;
  final String semanticLabel;
}

_MessageDeliveryPresentation? _deliveryPresentation(String value) {
  const mappings = <String, (LoomDeliveryState, String)>{
    'Queued': (LoomDeliveryState.queued, 'Queued'),
    'Sending': (LoomDeliveryState.sending, 'Sending'),
    'Sent to Home Node': (LoomDeliveryState.sent, 'Sent'),
    'Delivered': (LoomDeliveryState.delivered, 'Delivered'),
    'Read': (LoomDeliveryState.read, 'Read'),
    'Failed': (LoomDeliveryState.failed, 'Failed'),
  };
  for (final entry in mappings.entries) {
    final suffix = ' · ${entry.key}';
    if (!value.endsWith(suffix)) {
      continue;
    }
    return _MessageDeliveryPresentation(
      time: value.substring(0, value.length - suffix.length),
      state: entry.value.$1,
      semanticLabel: entry.value.$2,
    );
  }
  return null;
}

/// Horizontal drag competes normally with the list's vertical recognizer;
/// trigger once on release, mirror for RTL, and never remove the message.
class LoomSwipeToReply extends StatefulWidget {
  const LoomSwipeToReply({required this.child, this.onReply, super.key});
  final Widget child;
  final VoidCallback? onReply;
  @override
  State<LoomSwipeToReply> createState() => _LoomSwipeToReplyState();
}

class _LoomSwipeToReplyState extends State<LoomSwipeToReply> {
  double _offset = 0;
  bool _dragging = false;
  bool _armed = false;
  double? _origin;
  double get _direction =>
      Directionality.of(context) == TextDirection.rtl ? -1 : 1;
  void _reset() => setState(() {
        _offset = 0;
        _armed = false;
        _dragging = false;
        _origin = null;
      });
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: widget.onReply == null
            ? null
            : (details) => setState(() {
                  _dragging = true;
                  _origin = details.globalPosition.dx;
                }),
        onHorizontalDragUpdate: widget.onReply == null
            ? null
            : (details) {
                final next = ((details.globalPosition.dx -
                            (_origin ?? details.globalPosition.dx)) *
                        _direction)
                    .clamp(0.0, 72.0);
                if (next >= 52 && !_armed) {
                  _armed = true;
                  HapticFeedback.selectionClick();
                }
                if (next < 52) {
                  _armed = false;
                }
                setState(() => _offset = next);
              },
        onHorizontalDragEnd: widget.onReply == null
            ? null
            : (_) {
                final reply = _armed;
                _reset();
                if (reply) {
                  widget.onReply?.call();
                }
              },
        onHorizontalDragCancel: widget.onReply == null ? null : _reset,
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            if (_offset > 0)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 12),
                child: Opacity(
                  opacity: (_offset / 52).clamp(0.0, 1.0),
                  child: Icon(LoomIcons.reply_rounded,
                      color: context.loom.primary),
                ),
              ),
            AnimatedContainer(
              duration: _dragging ||
                      LoomAccessibility.fromContext(context).reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(_offset * _direction, 0, 0),
              child: widget.child,
            ),
          ],
        ),
      );
}

class _LinkedMessageText extends StatefulWidget {
  const _LinkedMessageText({
    required this.text,
    required this.selectable,
    this.onLinkTap,
    this.style,
  });
  final String text;
  final bool selectable;
  final TextStyle? style;
  final ValueChanged<Uri>? onLinkTap;
  @override
  State<_LinkedMessageText> createState() => _LinkedMessageTextState();
}

class _LinkedMessageTextState extends State<_LinkedMessageText> {
  final _recognizers = <TapGestureRecognizer>[];
  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final link in loomDetectLinks(widget.text)) {
      spans.add(TextSpan(text: widget.text.substring(offset, link.start)));
      final r = TapGestureRecognizer()
        ..onTap = () => widget.onLinkTap?.call(link.uri);
      _recognizers.add(r);
      spans.add(
        TextSpan(
          text: widget.text.substring(link.start, link.end),
          style: const TextStyle(decoration: TextDecoration.underline),
          recognizer: widget.onLinkTap == null ? null : r,
        ),
      );
      offset = link.end;
    }
    spans.add(TextSpan(text: widget.text.substring(offset)));
    final span = TextSpan(style: widget.style, children: spans);
    return widget.selectable ? SelectableText.rich(span) : Text.rich(span);
  }
}

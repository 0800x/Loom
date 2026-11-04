import 'message_content.dart';

/// One sender's active reaction on a message.
class LoomReactionEntry {
  const LoomReactionEntry({required this.emoji, required this.sender});

  final String emoji;
  final String sender;
}

/// The presentation state produced by authenticated control documents.
class LoomMessageFold {
  final Map<String, LoomReactionEntry> _reactions = {};

  bool edited = false;
  bool deletedForEveryone = false;
  String? editedText;

  List<LoomReactionEntry> get reactions =>
      List<LoomReactionEntry>.unmodifiable(_reactions.values);

  void toggleReaction({required String emoji, required String sender}) {
    if (deletedForEveryone) return;
    final key = sender.toLowerCase();
    final current = _reactions[key];
    if (current?.emoji == emoji) {
      _reactions.remove(key);
    } else {
      _reactions[key] = LoomReactionEntry(emoji: emoji, sender: sender);
    }
  }

  void applyEdit(String text) {
    if (deletedForEveryone) return;
    edited = true;
    editedText = text;
  }

  void deleteForEveryone() {
    deletedForEveryone = true;
    editedText = null;
    _reactions.clear();
  }
}

/// Result of classifying one decrypted history row before rendering.
class LoomFoldClassification<T> {
  const LoomFoldClassification({this.hidden = false, this.control});

  final bool hidden;
  final LoomMessageControl? control;
}

/// Folds authenticated reaction/edit/delete control records into their target
/// messages and removes control rows from the visible history.
///
/// The input is normally chronological, but controls are applied by timestamp
/// so pagination or merged group history does not make an older mutation
/// overwrite a newer one. Edits and deletes are accepted only from the
/// original message sender; reactions may come from any conversation member.
class LoomControlFold<T> {
  final Map<String, LoomMessageFold> folds = {};
  final Map<String, DateTime> typing = {};

  List<T> apply({
    required List<T> items,
    required LoomFoldClassification<T>? Function(T item) prepare,
    required String Function(T item) keyOf,
    required String Function(T item) senderOf,
    required DateTime Function(T item) timeOf,
  }) {
    folds.clear();
    typing.clear();

    final classifications = <LoomFoldClassification<T>?>[];
    final originalSenders = <String, String>{};
    final controls = <({T item, LoomMessageControl control})>[];

    for (final item in items) {
      final classification = prepare(item);
      classifications.add(classification);
      if (classification == null) {
        originalSenders.putIfAbsent(keyOf(item), () => senderOf(item));
      } else if (!classification.hidden && classification.control != null) {
        controls.add((item: item, control: classification.control!));
      }
    }

    controls.sort((a, b) => timeOf(a.item).compareTo(timeOf(b.item)));

    for (final event in controls) {
      final control = event.control;
      final sender = senderOf(event.item);
      final timestamp = timeOf(event.item);

      if (control.op == LoomMessageControlOp.typing) {
        final previous = typing[sender];
        if (previous == null || timestamp.isAfter(previous)) {
          typing[sender] = timestamp;
        }
        continue;
      }

      final originalSender = originalSenders[control.target];
      if (originalSender == null) continue;

      final fold = folds.putIfAbsent(control.target, LoomMessageFold.new);
      switch (control.op) {
        case LoomMessageControlOp.react:
          fold.toggleReaction(emoji: control.emoji, sender: sender);
          break;
        case LoomMessageControlOp.edit:
          if (sender.toLowerCase() == originalSender.toLowerCase()) {
            fold.applyEdit(control.text);
          }
          break;
        case LoomMessageControlOp.delete:
          if (sender.toLowerCase() == originalSender.toLowerCase()) {
            fold.deleteForEveryone();
          }
          break;
        case LoomMessageControlOp.typing:
          // Typing frames are handled before target lookup.
          break;
      }
    }

    final visible = <T>[];
    for (var index = 0; index < items.length; index++) {
      final classification = classifications[index];
      if (classification == null) {
        visible.add(items[index]);
      }
      // Classified controls, malformed rows and unreadable system rows are
      // intentionally consumed rather than rendered as chat bubbles.
    }
    return List<T>.unmodifiable(visible);
  }
}

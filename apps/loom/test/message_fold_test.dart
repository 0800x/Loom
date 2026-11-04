import 'package:flutter_test/flutter_test.dart';

import '../lib/features/messaging/application/message_content.dart';
import '../lib/features/messaging/application/message_fold.dart';

void main() {
  final base = DateTime.utc(2026, 11, 4, 10);

  test(
    'folds reactions into their target message and toggles own reaction',
    () {
      final fold = LoomControlFold<String>();
      final result = fold.apply(
        items: const ['message-1', 'reaction-1', 'reaction-2', 'reaction-3'],
        prepare: (item) => switch (item) {
          'message-1' => null,
          'reaction-1' => const LoomFoldClassification(
            control: LoomMessageControl.react(target: 'message-1', emoji: '👍'),
          ),
          'reaction-2' => const LoomFoldClassification(
            control: LoomMessageControl.react(target: 'message-1', emoji: '❤️'),
          ),
          _ => const LoomFoldClassification(
            control: LoomMessageControl.react(target: 'message-1', emoji: '❤️'),
          ),
        },
        keyOf: (item) => item == 'message-1' ? item : 'control',
        senderOf: (item) => switch (item) {
          'message-1' => 'alice',
          'reaction-1' => 'bob',
          'reaction-2' => 'alice',
          _ => 'alice',
        },
        timeOf: (item) => base.add(
          Duration(
            seconds: switch (item) {
              'message-1' => 0,
              'reaction-1' => 1,
              'reaction-2' => 2,
              _ => 3,
            },
          ),
        ),
      );

      expect(result, ['message-1']);
      final reactions = fold.folds['message-1']!.reactions;
      expect(reactions, hasLength(1));
      expect(reactions.single.emoji, '👍');
      expect(reactions.single.sender, 'bob');
    },
  );

  test('only the original sender can edit or delete a message', () {
    final fold = LoomControlFold<String>();
    fold.apply(
      items: const ['message-1', 'edit-by-bob', 'delete-by-bob'],
      prepare: (item) => switch (item) {
        'message-1' => null,
        'edit-by-bob' => const LoomFoldClassification(
          control: LoomMessageControl.edit(
            target: 'message-1',
            text: 'forged edit',
          ),
        ),
        _ => const LoomFoldClassification(
          control: LoomMessageControl.delete(target: 'message-1'),
        ),
      },
      keyOf: (item) => item,
      senderOf: (item) => item == 'message-1' ? 'alice' : 'bob',
      timeOf: (item) =>
          base.add(Duration(seconds: item == 'message-1' ? 0 : 1)),
    );

    expect(fold.folds, isEmpty);
  });

  test('applies authorized edit and delete in chronological order', () {
    final fold = LoomControlFold<String>();
    fold.apply(
      items: const ['message-1', 'edit', 'delete'],
      prepare: (item) => switch (item) {
        'message-1' => null,
        'edit' => const LoomFoldClassification(
          control: LoomMessageControl.edit(
            target: 'message-1',
            text: 'updated text',
          ),
        ),
        _ => const LoomFoldClassification(
          control: LoomMessageControl.delete(target: 'message-1'),
        ),
      },
      keyOf: (item) => item,
      senderOf: (_) => 'alice',
      timeOf: (item) => base.add(
        Duration(
          seconds: switch (item) {
            'message-1' => 0,
            'edit' => 1,
            _ => 2,
          },
        ),
      ),
    );

    expect(fold.folds['message-1']!.edited, isTrue);
    expect(fold.folds['message-1']!.editedText, isNull);
    expect(fold.folds['message-1']!.deletedForEveryone, isTrue);
  });

  test('collects latest typing timestamp and removes control rows', () {
    final fold = LoomControlFold<String>();
    final result = fold.apply(
      items: const ['message-1', 'typing-1', 'typing-2'],
      prepare: (item) => switch (item) {
        'message-1' => null,
        _ => const LoomFoldClassification(control: LoomMessageControl.typing()),
      },
      keyOf: (item) => item,
      senderOf: (_) => 'bob',
      timeOf: (item) => base.add(Duration(seconds: item == 'typing-2' ? 2 : 1)),
    );

    expect(result, ['message-1']);
    expect(fold.typing['bob'], base.add(const Duration(seconds: 2)));
  });
}

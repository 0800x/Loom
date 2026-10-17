import 'package:flutter/widgets.dart';

import '../../home/presentation/messenger_shell.dart';

/// Compatibility entry point kept for older routes/tests.
///
/// Production messaging now has a single UI implementation: [MessengerShell].
/// Keeping this adapter prevents the simplified live screen from diverging from
/// the original Liquid Glass shell again.
@Deprecated('Use MessengerShell; Loom now has one production messenger UI.')
class LoomLiveMessengerScreen extends StatelessWidget {
  const LoomLiveMessengerScreen({super.key});

  @override
  Widget build(BuildContext context) => const MessengerShell();
}

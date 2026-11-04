import 'package:flutter/material.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

import '../../messaging/application/messaging_session_controller.dart';

class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key, required this.messaging});

  final LoomMessagingSessionController messaging;

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _query = TextEditingController();
  String _value = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = LoomAppLock.instance.locked;
    final enabled = widget.messaging.searchEnabled;
    final results = locked || !enabled || _value.trim().isEmpty
        ? <({LoomMessageRecord record, String body})>[]
        : widget.messaging.searchLocalMessages(_value);

    return Scaffold(
      appBar: AppBar(title: const Text('Search messages')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _value = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search messages on this device',
                suffixIcon: IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _query.clear();
                    setState(() => _value = '');
                  },
                  icon: const Icon(Icons.close),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (locked)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Unlock Loom to search local messages.'),
            )
          else if (!enabled)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Enable local message search in Privacy settings.'),
            )
          else if (_value.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Search decrypted messages stored on this device.'),
            )
          else if (results.isEmpty)
            const Expanded(child: Center(child: Text('No matching messages')))
          else
            Expanded(
              child: ListView.separated(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final hit = results[index];
                  final record = hit.record;
                  return ListTile(
                    title: Text(
                      hit.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      record.senderAddress.toString() +
                          ' · ' +
                          record.createdAt.toLocal().toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    leading: const Icon(Icons.message_outlined),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

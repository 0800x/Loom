import 'package:flutter/foundation.dart';

/// Temporary opt-in stages for reproducing calls on release Android builds.
/// Call sites pass literals, enums, counts or error classes, never stored values,
/// account/call identifiers, tokens, SDP, ICE candidates or media contents.
void traceLoomCall(String stage) {
  if (const bool.fromEnvironment('LOOM_CALL_TRACE')) {
    debugPrint('[LoomCalls] $stage');
  }
}

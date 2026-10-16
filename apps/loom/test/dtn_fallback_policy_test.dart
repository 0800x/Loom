import 'dart:async';
import 'dart:io';

import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('definitive HTTP failures never enter DTN fallback', () {
    for (final status in <int>[400, 401, 403, 404, 409, 422, 429]) {
      expect(
        LoomDtnFallbackPolicy.shouldFallback(
          LoomHttpStatusException(
            statusCode: status,
            message: 'rejected',
          ),
        ),
        isFalse,
        reason: 'HTTP $status must remain authoritative',
      );
    }
  });

  test('temporary HTTP failures may enter DTN fallback', () {
    for (final status in <int>[408, 425, 500, 502, 503, 504]) {
      expect(
        LoomDtnFallbackPolicy.shouldFallback(
          LoomHttpStatusException(
            statusCode: status,
            message: 'temporary',
          ),
        ),
        isTrue,
        reason: 'HTTP $status is retryable transport/server failure',
      );
    }
  });

  test('transport outages may enter DTN fallback', () {
    expect(
      LoomDtnFallbackPolicy.shouldFallback(
        const LoomMessagingTransportUnavailable('no route'),
      ),
      isTrue,
    );
    expect(
      LoomDtnFallbackPolicy.shouldFallback(
        const SocketException('offline'),
      ),
      isTrue,
    );
    expect(
      LoomDtnFallbackPolicy.shouldFallback(
        TimeoutException('timeout'),
      ),
      isTrue,
    );
  });

  test('protocol and local validation failures do not enter DTN', () {
    expect(
      LoomDtnFallbackPolicy.shouldFallback(
        const LoomProtocolException('malformed receipt'),
      ),
      isFalse,
    );
    expect(
      LoomDtnFallbackPolicy.shouldFallback(StateError('invalid state')),
      isFalse,
    );
    expect(
      LoomDtnFallbackPolicy.shouldFallback(
        const FormatException('invalid envelope'),
      ),
      isFalse,
    );
  });
}

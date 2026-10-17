export interface LoomIncomingCallPush {
  callId: string;
  conversationId: string;
  callerIdentityId: string;
  callerAddress: string;
  callerDisplayName: string;
  targetIdentityId: string;
  mediaKind: 'audio' | 'video';
  expiresAt: string;
}

/// Boundary for a future platform push provider (for example FCM/APNs).
///
/// The default implementation is deliberately disabled. A foreground WebSocket
/// cannot wake an app process that the OS has suspended or terminated, and
/// Loom must not pretend otherwise.
export interface LoomCallPushGateway {
  readonly available: boolean;
  wakeIncomingCall(call: LoomIncomingCallPush): Promise<void>;
}

export class DisabledLoomCallPushGateway implements LoomCallPushGateway {
  readonly available = false;

  async wakeIncomingCall(_call: LoomIncomingCallPush): Promise<void> {
    // No-op by design. Pending calls remain retrievable when the app opens.
  }
}

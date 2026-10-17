import 'package:loom_design/loom_design.dart';
import 'package:flutter/foundation.dart';

/// Deterministic visual fixtures for Design Lab and explicit preview states.
///
/// This file is not a repository, transport, cache, or backend adapter. Values
/// must never be interpreted as live network/security state.
@immutable
class PreviewConversation {
  const PreviewConversation({
    required this.name,
    required this.preview,
    required this.time,
    this.unread = 0,
    this.presence = false,
    this.muted = false,
    this.pinned = false,
    this.draft = false,
    this.typing = false,
    this.delivery = LoomDeliveryState.none,
  });

  final String name;
  final String preview;
  final String time;
  final int unread;
  final bool presence;
  final bool muted;
  final bool pinned;
  final bool draft;
  final bool typing;
  final LoomDeliveryState delivery;
}

@immutable
class PreviewNode {
  const PreviewNode({
    required this.flag,
    required this.name,
    required this.location,
    required this.latency,
    required this.registration,
    required this.federation,
    this.capacity,
  });

  final String flag;
  final String name;
  final String location;
  final String latency;
  final String registration;
  final String federation;
  final String? capacity;
}

@immutable
class PreviewNodeDetail {
  const PreviewNodeDetail({
    required this.name,
    required this.domain,
    required this.nodeId,
    required this.fingerprint,
    required this.operatorCountry,
    required this.networkJurisdiction,
    required this.operatorName,
    required this.tlsState,
    required this.protocol,
    required this.federationMode,
    required this.registration,
    required this.capacity,
  });

  final String name;
  final String domain;
  final String nodeId;
  final String fingerprint;
  final String operatorCountry;
  final String networkJurisdiction;
  final String operatorName;
  final String tlsState;
  final String protocol;
  final String federationMode;
  final String registration;
  final String capacity;
}

@immutable
class PreviewProfile {
  const PreviewProfile({
    required this.name,
    required this.username,
    required this.address,
    required this.homeNode,
    required this.fingerprint,
  });

  final String name;
  final String username;
  final String address;
  final String homeNode;
  final String fingerprint;
}

@immutable
class PreviewMessage {
  const PreviewMessage({
    required this.text,
    required this.time,
    required this.mine,
  });

  final String text;
  final String time;
  final bool mine;
}

abstract final class LoomPreviewData {
  static const conversations = <PreviewConversation>[
    PreviewConversation(
      name: 'Maya Brooks',
      preview: 'Can we switch to the local Node?',
      time: '09:41',
      unread: 2,
      presence: true,
      pinned: true,
    ),
    PreviewConversation(
      name: 'Project Cedar',
      preview: 'Nora: latest build is ready',
      time: '09:26',
      muted: true,
    ),
    PreviewConversation(
      name: 'Ethan Cole',
      preview: 'Voice message · 0:24',
      time: 'Yesterday',
      delivery: LoomDeliveryState.read,
    ),
    PreviewConversation(
      name: 'Family',
      preview: 'Dinner at 8 🍲',
      time: 'Mon',
      unread: 4,
    ),
    PreviewConversation(
      name: 'Leo Hart',
      preview: 'Queued while Node was unreachable',
      time: 'Sun',
      delivery: LoomDeliveryState.sending,
    ),
    PreviewConversation(
      name: 'Iris Lane',
      preview: 'This text never leaves Design Lab',
      time: 'Sun',
      draft: true,
    ),
    PreviewConversation(
      name: 'Finn Wells',
      preview: '',
      time: 'Sat',
      typing: true,
    ),
  ];

  static const messages = <PreviewMessage>[
    PreviewMessage(
      text: 'I can reach the house Node again.',
      time: '09:44',
      mine: false,
    ),
    PreviewMessage(
      text: 'Nice. Loom should keep the route change invisible.',
      time: '09:44',
      mine: true,
    ),
    PreviewMessage(
      text: 'Public Internet is shaky, but the LAN path is fine.',
      time: '09:43',
      mine: false,
    ),
  ];

  static const nodes = <PreviewNode>[
    PreviewNode(
      flag: '🇮🇷',
      name: 'North Community',
      location: 'Iran · Alborz',
      latency: '9 ms',
      registration: 'Registration open',
      federation: 'Federation enabled',
      capacity: '428 / 2000',
    ),
    PreviewNode(
      flag: '🇮🇷',
      name: 'Central Commons',
      location: 'Iran · Central',
      latency: '22 ms',
      registration: 'Invite only',
      federation: 'Trusted federation',
      capacity: '1180 / 2500',
    ),
    PreviewNode(
      flag: '🇩🇪',
      name: 'Nuremberg Cooperative',
      location: 'Germany · Bavaria',
      latency: '84 ms',
      registration: 'Approval required',
      federation: 'Federation enabled',
    ),
  ];

  static const nodeDetail = PreviewNodeDetail(
    name: 'North Community',
    domain: 'chat.cedar.example',
    nodeId: 'chn:node:••••7A3C',
    fingerprint: 'B2:41:••:••:91:EF',
    operatorCountry: 'Iran',
    networkJurisdiction: 'Iran',
    operatorName: 'Community-operated',
    tlsState: 'Preview only',
    protocol: 'loom-federation-v1',
    federationMode: 'Preview only',
    registration: 'Preview only',
    capacity: '428 / 2000',
  );

  static const profile = PreviewProfile(
    name: 'Maya Brooks',
    username: '@maya',
    address: '@maya:cedar.example',
    homeNode: 'cedar.example',
    fingerprint: 'B2:41:••:••:91:EF',
  );
}

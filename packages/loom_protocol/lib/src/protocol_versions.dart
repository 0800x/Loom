abstract final class LoomProtocolVersions {
  static const String identityV1 = 'Loom-Identity-v1';
  static const String directMessageV1 = 'Loom-Direct-v1';

  // Architecture v2 identifiers are reserved here before production codecs
  // ship so version negotiation cannot drift across packages.
  static const String sessionV2 = 'Loom-Session-v2';
  static const int innerEnvelopeV2 = 2;
  static const int sessionCiphertextEnvelopeV2 = 2;
  static const int outerEnvelopeV2 = 2;
  static const int peerProtocolV2 = 2;
  static const int capabilityProtocolV2 = 2;
  static const int gatewayAdvertisementV2 = 2;
  static const int deliveryReceiptV2 = 2;

  static bool isKnownSession(String value) =>
      value == directMessageV1 || value == sessionV2;

  static bool canSendWithSession(String value) => value == sessionV2;
}

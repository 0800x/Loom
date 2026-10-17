import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../../messaging/application/android_nearby_radio_stack.dart';
import '../../messaging/application/authorized_device_direct_transport_signer.dart';
import '../../messaging/application/proximity_gateway_session_runner.dart';
import '../../onboarding/application/onboarding_controller.dart';

class LoomNearbyDiagnosticsScreen extends StatefulWidget {
  const LoomNearbyDiagnosticsScreen({super.key});

  @override
  State<LoomNearbyDiagnosticsScreen> createState() =>
      _LoomNearbyDiagnosticsScreenState();
}

class _LoomNearbyDiagnosticsScreenState
    extends State<LoomNearbyDiagnosticsScreen> {
  final LoomAndroidNearbyRadioStack _radios = LoomAndroidNearbyRadioStack();
  final LoomProximityGatewaySessionRunner _lastMile =
      LoomProximityGatewaySessionRunner();
  final Map<LoomNearbyBearer, LoomNearbyAdvertisingSession>
  _advertisingSessions = <LoomNearbyBearer, LoomNearbyAdvertisingSession>{};
  final Map<LoomNearbyBearer, StreamSubscription<LoomNearbyLink>>
  _advertisingSubscriptions =
      <LoomNearbyBearer, StreamSubscription<LoomNearbyLink>>{};

  Set<LoomNearbyBearer> _supported = const <LoomNearbyBearer>{};
  LoomNearbyBearer? _foregroundBearer;
  LoomNearbyBearer? _lastMileRecipientBearer;
  LoomNearbyAdvertisingSession? _lastMileRecipientSession;
  StreamSubscription<LoomNearbyLink>? _lastMileRecipientSubscription;
  bool _busy = false;
  bool _lastMileHandlingLink = false;
  String _status = 'Not checked yet';

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    for (final subscription in _advertisingSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final session in _advertisingSessions.values) {
      unawaited(session.close());
    }
    unawaited(_lastMileRecipientSubscription?.cancel());
    unawaited(_lastMileRecipientSession?.close());
    if (_foregroundBearer != null) {
      unawaited(_radios.stopForegroundMode());
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Checking native radio capabilities…';
    });
    try {
      if (!Platform.isAndroid) {
        if (!mounted) return;
        setState(() {
          _supported = const <LoomNearbyBearer>{};
          _status = 'Android native Nearby diagnostics are unavailable here.';
        });
        return;
      }
      final supported = await _radios.supportedBearers();
      if (!mounted) return;
      setState(() {
        _supported = supported;
        _status = supported.isEmpty
            ? 'No supported Android Nearby bearer was reported.'
            : 'Native capability probe completed.';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Capability probe failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestPermissions() async {
    if (_busy) return;
    if (_supported.isEmpty) await _refresh();
    if (_supported.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Requesting Android Nearby permissions…';
    });
    try {
      final granted = await _radios.requestPermissionsFor(_supported);
      if (!mounted) return;
      setState(() {
        _status = granted
            ? 'Nearby permissions granted for the supported bearers.'
            : 'Nearby permission request was denied or only partially granted.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Permission request failed: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan(LoomNearbyBearer bearer) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Scanning with ${_label(bearer)} for 5 seconds…';
    });
    try {
      if (!await _radios.requestPermissionsFor(<LoomNearbyBearer>{bearer})) {
        if (mounted) {
          setState(
            () => _status = '${_label(bearer)} permission was not granted.',
          );
        }
        return;
      }
      final candidates = await _radios
          .adapterFor(bearer)
          .scan(timeout: const Duration(seconds: 5))
          .toList();
      if (mounted) {
        setState(
          () => _status =
              '${_label(bearer)} scan completed: '
              '${candidates.length} Loom candidate(s) discovered.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '${_label(bearer)} scan failed: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startAdvertising(LoomNearbyBearer bearer) async {
    if (_busy || _advertisingSessions.containsKey(bearer)) return;
    setState(() {
      _busy = true;
      _status = 'Starting ${_label(bearer)} diagnostic advertisement…';
    });
    try {
      if (!await _radios.requestPermissionsFor(<LoomNearbyBearer>{bearer})) {
        return;
      }
      final session = await _radios
          .adapterFor(bearer)
          .advertise(_advertisement(bearer));
      if (!mounted) {
        await session.close();
        return;
      }
      final subscription = session.incomingLinks.listen((link) {
        unawaited(link.close());
        if (mounted) {
          setState(
            () => _status =
                '${_label(bearer)} accepted a diagnostic Nearby link.',
          );
        }
      });
      setState(() {
        _advertisingSessions[bearer] = session;
        _advertisingSubscriptions[bearer] = subscription;
        _status =
            '${_label(bearer)} is advertising. Scan from the other phone.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '${_label(bearer)} advertise failed: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopAdvertising(LoomNearbyBearer bearer) async {
    final session = _advertisingSessions.remove(bearer);
    if (session == null) return;
    final subscription = _advertisingSubscriptions.remove(bearer);
    await subscription?.cancel();
    await session.close();
    if (mounted) {
      setState(() => _status = '${_label(bearer)} advertisement stopped.');
    }
  }

  Future<LoomAuthorizedDeviceDirectTransportSigner> _deviceSigner() async {
    final onboarding = LoomOnboardingScope.of(context);
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    if (identity == null || receipt == null) {
      throw StateError(
        'A registered Loom device is required for last-mile mode.',
      );
    }
    return LoomAuthorizedDeviceDirectTransportSigner(
      deviceSecurity: LoomDeviceSecurityCoreV1(),
      identityId: identity.identityId,
      deviceId: receipt.deviceId,
    );
  }

  Future<void> _startLastMileRecipient(LoomNearbyBearer bearer) async {
    if (_busy || _lastMileRecipientSession != null) return;
    final onboarding = LoomOnboardingScope.of(context);
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    final node = onboarding.nodes.selectedNode;
    if (identity == null || receipt == null || node == null) {
      setState(
        () => _status = 'A saved Loom identity and Home Node are required.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _status =
          'Starting offline-recipient last-mile mode on ${_label(bearer)}…';
    });
    try {
      if (!await _radios.requestPermissionsFor(<LoomNearbyBearer>{bearer})) {
        throw StateError('Nearby permission was not granted');
      }
      await _radios.startForegroundMode(bearer);
      _foregroundBearer = bearer;
      final signer = await _deviceSigner();
      final session = await _radios
          .adapterFor(bearer)
          .advertise(_advertisement(bearer));
      final subscription = session.incomingLinks.listen(
        (link) {
          if (_lastMileHandlingLink) {
            unawaited(link.close());
            return;
          }
          _lastMileHandlingLink = true;
          unawaited(() async {
            try {
              if (mounted) {
                setState(
                  () => _status =
                      'Gateway connected. Verifying lease and receiving encrypted messages…',
                );
              }
              final delivered = await _lastMile.runRecipient(
                link: link,
                recipientSigner: signer,
                recipientIdentityId: identity.identityId,
                recipientDeviceId: receipt.deviceId,
                recipientNodeId: node.nodeId,
                recipientNodeDomain: node.domain,
                bearer: _gatewayBearer(bearer),
              );
              if (mounted) {
                setState(
                  () => _status =
                      'Last-mile recipient session complete: '
                      '$delivered encrypted message(s) committed locally.',
                );
              }
            } catch (error) {
              if (mounted) {
                setState(
                  () => _status = 'Last-mile recipient session failed: $error',
                );
              }
            } finally {
              _lastMileHandlingLink = false;
            }
          }());
        },
        onError: (Object error) {
          if (mounted) {
            setState(() => _status = 'Last-mile listener failed: $error');
          }
        },
      );
      if (!mounted) {
        await subscription.cancel();
        await session.close();
        return;
      }
      setState(() {
        _lastMileRecipientBearer = bearer;
        _lastMileRecipientSession = session;
        _lastMileRecipientSubscription = subscription;
        _status =
            'Offline recipient mode active on ${_label(bearer)}. '
            'Internet may now be disabled on this phone; run Gateway Deliver on a nearby online phone.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = 'Could not start last-mile recipient mode: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopLastMileRecipient() async {
    final subscription = _lastMileRecipientSubscription;
    final session = _lastMileRecipientSession;
    _lastMileRecipientSubscription = null;
    _lastMileRecipientSession = null;
    _lastMileRecipientBearer = null;
    await subscription?.cancel();
    await session?.close();
    if (_foregroundBearer != null) {
      await _radios.stopForegroundMode();
      _foregroundBearer = null;
    }
    if (mounted) {
      setState(() => _status = 'Offline recipient last-mile mode stopped.');
    }
  }

  Future<void> _deliverAsGateway(LoomNearbyBearer bearer) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Looking for offline Loom recipients over ${_label(bearer)}…';
    });
    try {
      if (!await _radios.requestPermissionsFor(<LoomNearbyBearer>{bearer})) {
        throw StateError('Nearby permission was not granted');
      }
      final signer = await _deviceSigner();
      final candidates = await _radios
          .adapterFor(bearer)
          .scan(timeout: const Duration(seconds: 8))
          .toList();
      if (candidates.isEmpty) {
        if (mounted) {
          setState(
            () => _status = 'No ${_label(bearer)} Loom candidates found.',
          );
        }
        return;
      }
      Object? lastError;
      for (final candidate in candidates) {
        try {
          if (mounted) {
            setState(
              () => _status =
                  'Connecting to a candidate and requesting a recipient-authorized lease…',
            );
          }
          final link = await _radios.adapterFor(bearer).connect(candidate);
          final result = await _lastMile.runGateway(
            link: link,
            gatewaySigner: signer,
          );
          if (mounted) {
            setState(
              () => _status =
                  'Gateway session complete: ${result.offered} offered, '
                  '${result.delivered} delivered to the nearby offline recipient, '
                  '${result.custodyAcknowledged} custody ACK(s).',
            );
          }
          return;
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError ??
          StateError('No candidate accepted a last-mile gateway session');
    } catch (error) {
      if (mounted) setState(() => _status = 'Gateway delivery failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startForeground(LoomNearbyBearer bearer) async {
    if (_busy) return;
    try {
      if (!await _radios.requestPermissionsFor(<LoomNearbyBearer>{bearer})) {
        return;
      }
      await _radios.startForegroundMode(bearer);
      if (mounted) {
        setState(() {
          _foregroundBearer = bearer;
          _status =
              'Nearby foreground service is active for ${_label(bearer)}.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Nearby foreground service failed: $error');
      }
    }
  }

  Future<void> _stopForeground() async {
    await _radios.stopForegroundMode();
    if (mounted) {
      setState(() {
        _foregroundBearer = null;
        _status = 'Nearby foreground service stopped.';
      });
    }
  }

  LoomNearbyAdvertisement _advertisement(LoomNearbyBearer bearer) =>
      LoomNearbyAdvertisement(
        protocolVersion: 1,
        rendezvousId: _newRendezvousId(),
        bearers: <LoomNearbyBearer>[bearer],
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
      );

  static LoomProximityGatewayBearer _gatewayBearer(
    LoomNearbyBearer bearer,
  ) => switch (bearer) {
    LoomNearbyBearer.bluetoothLowEnergy => LoomProximityGatewayBearer.ble,
    LoomNearbyBearer.wifiDirect => LoomProximityGatewayBearer.wifiDirect,
    LoomNearbyBearer.wifiAware => LoomProximityGatewayBearer.wifiAware,
    _ => throw UnsupportedError('Unsupported last-mile bearer: $bearer'),
  };

  static String _newRendezvousId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _label(LoomNearbyBearer bearer) => switch (bearer) {
    LoomNearbyBearer.bluetoothLowEnergy => 'Bluetooth LE',
    LoomNearbyBearer.wifiDirect => 'Wi-Fi Direct',
    LoomNearbyBearer.wifiAware => 'Wi-Fi Aware',
    LoomNearbyBearer.multipeer => 'Multipeer',
    LoomNearbyBearer.localPeer => 'Local peer',
  };

  @override
  Widget build(BuildContext context) {
    final nativeBearers = <LoomNearbyBearer>[
      LoomNearbyBearer.bluetoothLowEnergy,
      LoomNearbyBearer.wifiDirect,
      LoomNearbyBearer.wifiAware,
    ];
    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Nearby diagnostics', 'عیب‌یابی Nearby')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(LoomSpacing.md),
        children: [
          LoomSettingsCard(
            padding: const EdgeInsets.all(LoomSpacing.md),
            child: Text(
              tr(
                context,
                'Radio diagnostics plus the Internet-to-Nearby last-mile test. Offline Recipient creates a recipient-signed short lease; Gateway Deliver uses the Internet to fetch only that recipient’s encrypted pending traffic and forwards it over the selected nearby bearer.',
                'عیب‌یابی رادیو و تست آخرین‌مایل اینترنت به Nearby. حالت گیرنده آفلاین یک مجوز کوتاه‌عمر امضاشده توسط خود دستگاه می‌سازد؛ Gateway Deliver فقط پیام‌های رمز‌شده همان گیرنده را از اینترنت می‌گیرد و با bearer انتخابی تحویل می‌دهد.',
              ),
            ),
          ),
          const SizedBox(height: LoomSpacing.md),
          for (final bearer in nativeBearers)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(LoomSpacing.sm),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        _supported.contains(bearer)
                            ? LoomIcons.check_circle_rounded
                            : LoomIcons.error_outline_rounded,
                      ),
                      title: Text(_label(bearer)),
                      subtitle: Text(
                        _supported.contains(bearer)
                            ? 'Supported by this device'
                            : 'Not reported as supported',
                      ),
                    ),
                    if (_supported.contains(bearer)) ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : _advertisingSessions.containsKey(bearer)
                                  ? () => _stopAdvertising(bearer)
                                  : () => _startAdvertising(bearer),
                              child: Text(
                                _advertisingSessions.containsKey(bearer)
                                    ? 'Stop advertise'
                                    : 'Diagnostic advertise',
                              ),
                            ),
                          ),
                          const SizedBox(width: LoomSpacing.sm),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy ? null : () => _scan(bearer),
                              child: const Text('Diagnostic scan'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: LoomSpacing.sm),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy
                                  ? null
                                  : _lastMileRecipientBearer == bearer
                                  ? _stopLastMileRecipient
                                  : _lastMileRecipientBearer == null
                                  ? () => _startLastMileRecipient(bearer)
                                  : null,
                              child: Text(
                                _lastMileRecipientBearer == bearer
                                    ? 'Stop Offline Recipient'
                                    : 'Start Offline Recipient',
                              ),
                            ),
                          ),
                          const SizedBox(width: LoomSpacing.sm),
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  _busy || _lastMileRecipientBearer != null
                                  ? null
                                  : () => _deliverAsGateway(bearer),
                              child: const Text('Gateway Deliver'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _requestPermissions,
            icon: const Icon(LoomIcons.admin_panel_settings_outlined),
            label: Text(
              tr(
                context,
                'Request Nearby permissions',
                'درخواست مجوزهای Nearby',
              ),
            ),
          ),
          const SizedBox(height: LoomSpacing.sm),
          OutlinedButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(LoomIcons.refresh_rounded),
            label: Text(
              tr(context, 'Refresh capabilities', 'بررسی دوباره قابلیت‌ها'),
            ),
          ),
          const SizedBox(height: LoomSpacing.sm),
          if (_foregroundBearer == null && _supported.isNotEmpty)
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _startForeground(_supported.first),
              icon: const Icon(LoomIcons.near_me_outlined),
              label: const Text('Start Nearby foreground service'),
            )
          else if (_foregroundBearer != null &&
              _lastMileRecipientBearer == null)
            OutlinedButton.icon(
              onPressed: _busy ? null : _stopForeground,
              icon: const Icon(LoomIcons.call_end_rounded),
              label: const Text('Stop Nearby foreground service'),
            ),
          const SizedBox(height: LoomSpacing.md),
          LoomSettingsCard(
            padding: const EdgeInsets.all(LoomSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(right: LoomSpacing.sm),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Expanded(child: Text(_status)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


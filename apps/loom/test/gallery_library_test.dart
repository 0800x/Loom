import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'widget_smoke_test.dart' show host, usePhoneViewport;

void main() {
  testWidgets('Recent includes screenshots and reloads after library changes', (
    tester,
  ) async {
    usePhoneViewport(tester);
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final calls = <MethodCall>[];
    var generation = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'requestPermissionExtend':
          return PermissionState.authorized.index;
        case 'getAssetPathList':
          return {
            'data': [
              {
                'id': 'camera',
                'name': 'Camera',
                'isAll': false,
                'assetCount': 1,
              },
              {'id': 'all', 'name': 'All', 'isAll': true, 'assetCount': 2},
            ],
          };
        case 'getAssetListPaged':
          return {
            'data': [
              {
                'id': generation == 0 ? 'screenshot' : 'new-screenshot',
                'type': 1,
                'width': 1080,
                'height': 1920,
                'createDt': 100,
                'modifiedDt': 200,
              },
              {
                'id': 'camera-photo',
                'type': 1,
                'width': 1920,
                'height': 1080,
                'createDt': 99,
                'modifiedDt': 99,
              },
            ],
          };
        case 'getThumb':
          return null;
        default:
          return true;
      }
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      host(
        const LoomGlassScope(
          quality: LoomGlassQuality.disabled,
          child: MessengerShell(preview: true),
        ),
      ),
    );
    await tester.tap(find.text('Maya Brooks').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    final pathCall = calls.firstWhere(
      (call) => call.method == 'getAssetPathList',
    );
    final orders =
        (((pathCall.arguments as Map)['option'] as Map)['child']
                as Map)['orders']
            as List;
    expect(orders.map((item) => (item as Map)['asc']), everyElement(false));
    expect(orders.length, 2);
    expect(
      (calls.firstWhere((c) => c.method == 'getAssetListPaged').arguments
          as Map)['id'],
      'all',
    );
    expect(find.byKey(const ValueKey('screenshot')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screenshot')));
    await tester.pumpAndSettle();
    generation++;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'com.fluttercandies/photo_manager/notify',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('change')),
      (_) {},
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new-screenshot')), findsOneWidget);
    expect(calls.where((c) => c.method == 'getAssetListPaged').length, 2);
    // Selection remains in the draft even if its asset leaves the current page.
    expect(find.text('1'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

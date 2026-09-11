import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/drive_session/drive_session_state.dart';
import 'package:signalahead_mobile/location/location_gateway.dart';
import 'package:signalahead_mobile/main.dart';
import 'drive_session/drive_session_state_test.dart'
    show TestLocation, TestCatalog;

void main() {
  testWidgets(
      'start requests permission; denial is actionable and not fake preparation',
      (tester) async {
    final location = TestLocation()..blocked = LocationBlocker.permissionDenied;
    final controller = DriveSessionController(
        location: location, createCatalogClient: TestCatalog.new);
    await tester.pumpWidget(SignalAheadApp(controller: controller));
    expect(location.requests, 0);
    await tester.tap(find.text('주행 시작'));
    await tester.pumpAndSettle();
    expect(location.requests, 1);
    expect(location.streams, 0);
    expect(controller.blocker, LocationBlocker.permissionDenied);
    expect(find.text('위치 설정 열기'), findsOneWidget);
    expect(find.text('주행 시작'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await location.updates.close();
    await location.services.close();
  });

  testWidgets(
      'small screen and large text remain scrollable with reachable stop action',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final location = TestLocation();
    final controller = DriveSessionController(
        location: location, createCatalogClient: TestCatalog.new);
    await tester.pumpWidget(SignalAheadApp(controller: controller));
    await tester.scrollUntilVisible(find.text('주행 시작'), 200);
    await tester.tap(find.text('주행 시작'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('주행 종료'), 200);
    await tester.tap(find.text('주행 종료'));
    await tester.pumpAndSettle();
    expect(controller.phase, DriveSessionPhase.stopped);
    expect(location.updates.hasListener, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await location.updates.close();
    await location.services.close();
  });
}

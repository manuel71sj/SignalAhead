import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/drive_session/drive_session_state.dart';
import 'package:signalahead_mobile/location/location_sample.dart';

void main() {
  test('session requests permission only after explicit start', () {
    var state = DriveSessionState.initial();
    expect(state.locationStreamActive, isFalse);

    state = state.reduce(const StartDriving(), () => 'session-1');
    expect(state.phase, DriveSessionPhase.requestingPermission);
    expect(state.locationStreamActive, isFalse);
  });

  test('pause and permission revoke stop location and invalidate prediction', () {
    var state = DriveSessionState.initial()
        .reduce(const StartDriving(), () => 'session-1')
        .reduce(const PermissionResolved(granted: true, blocker: null), () => 'unused')
        .reduce(const FirstFreshLocation(), () => 'unused');
    expect(state.locationStreamActive, isTrue);

    state = state.reduce(const AppPaused(), () => 'unused');
    expect(state.phase, DriveSessionPhase.paused);
    expect(state.locationStreamActive, isFalse);
    expect(state.predictionValid, isFalse);

    state = state.reduce(const PermissionRevoked(blocker: LocationBlocker.permissionDeniedForever), () => 'unused');
    expect(state.phase, DriveSessionPhase.stopped);
    expect(state.sessionId, isNull);
    expect(state.blocker, LocationBlocker.permissionDeniedForever);
  });

  test('platform invalid speed and course values normalize to null', () {
    expect(LocationSample.nonNegativeOrNull(-1), isNull);
    expect(LocationSample.nonNegativeOrNull(double.nan), isNull);
    expect(LocationSample.nonNegativeOrNull(0), 0);
    expect(LocationSample.courseOrNull(-1), isNull);
    expect(LocationSample.courseOrNull(360), isNull);
    expect(LocationSample.courseOrNull(90), 90);
  });
}

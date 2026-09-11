enum DriveSessionPhase { idle, requestingPermission, acquiringLocation, driving, paused, stopped }

enum LocationBlocker { permissionDenied, permissionDeniedForever, preciseLocationOff, serviceOff, staleLastKnown }

sealed class DriveSessionEvent {
  const DriveSessionEvent();
}

final class StartDriving extends DriveSessionEvent {
  const StartDriving();
}

final class PermissionResolved extends DriveSessionEvent {
  const PermissionResolved({required this.granted, required this.blocker});

  final bool granted;
  final LocationBlocker? blocker;
}

final class FirstFreshLocation extends DriveSessionEvent {
  const FirstFreshLocation();
}

final class AppPaused extends DriveSessionEvent {
  const AppPaused();
}

final class AppResumed extends DriveSessionEvent {
  const AppResumed();
}

final class PermissionRevoked extends DriveSessionEvent {
  const PermissionRevoked({required this.blocker});

  final LocationBlocker blocker;
}

final class StopDriving extends DriveSessionEvent {
  const StopDriving();
}

class DriveSessionState {
  const DriveSessionState({
    required this.phase,
    required this.sessionId,
    required this.blocker,
    required this.locationStreamActive,
    required this.predictionValid,
  });

  factory DriveSessionState.initial() => const DriveSessionState(
        phase: DriveSessionPhase.idle,
        sessionId: null,
        blocker: null,
        locationStreamActive: false,
        predictionValid: false,
      );

  final DriveSessionPhase phase;
  final String? sessionId;
  final LocationBlocker? blocker;
  final bool locationStreamActive;
  final bool predictionValid;

  DriveSessionState reduce(DriveSessionEvent event, String Function() newSessionId) {
    return switch (event) {
      StartDriving() when phase == DriveSessionPhase.idle || phase == DriveSessionPhase.stopped => DriveSessionState(
          phase: DriveSessionPhase.requestingPermission,
          sessionId: newSessionId(),
          blocker: null,
          locationStreamActive: false,
          predictionValid: false,
        ),
      PermissionResolved(:final granted, :final blocker) when phase == DriveSessionPhase.requestingPermission => granted
          ? DriveSessionState(
              phase: DriveSessionPhase.acquiringLocation,
              sessionId: sessionId,
              blocker: null,
              locationStreamActive: true,
              predictionValid: false,
            )
          : DriveSessionState(
              phase: DriveSessionPhase.stopped,
              sessionId: null,
              blocker: blocker ?? LocationBlocker.permissionDenied,
              locationStreamActive: false,
              predictionValid: false,
            ),
      FirstFreshLocation() when phase == DriveSessionPhase.acquiringLocation => DriveSessionState(
          phase: DriveSessionPhase.driving,
          sessionId: sessionId,
          blocker: null,
          locationStreamActive: true,
          predictionValid: false,
        ),
      AppPaused() when phase == DriveSessionPhase.driving || phase == DriveSessionPhase.acquiringLocation => DriveSessionState(
          phase: DriveSessionPhase.paused,
          sessionId: sessionId,
          blocker: null,
          locationStreamActive: false,
          predictionValid: false,
        ),
      AppResumed() when phase == DriveSessionPhase.paused => DriveSessionState(
          phase: DriveSessionPhase.acquiringLocation,
          sessionId: sessionId,
          blocker: null,
          locationStreamActive: true,
          predictionValid: false,
        ),
      PermissionRevoked(:final blocker) => DriveSessionState(
          phase: DriveSessionPhase.stopped,
          sessionId: null,
          blocker: blocker,
          locationStreamActive: false,
          predictionValid: false,
        ),
      StopDriving() => const DriveSessionState(
          phase: DriveSessionPhase.stopped,
          sessionId: null,
          blocker: null,
          locationStreamActive: false,
          predictionValid: false,
        ),
      _ => this,
    };
  }
}

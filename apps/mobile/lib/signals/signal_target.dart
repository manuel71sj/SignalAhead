/// A selected target, not evidence of a road match or operational approval.
/// Operational callers may create one only after verified spatial selection.
class SignalTarget {
  const SignalTarget({
    required this.sessionId,
    required this.targetGeneration,
    required this.provider,
    required this.intersectionKey,
    required this.approachKey,
    required this.catalogVersion,
    this.movement = 'straight',
  });

  final String sessionId;
  final int targetGeneration;
  final String provider;
  final String intersectionKey;
  final String approachKey;
  final String catalogVersion;
  final String movement;

  @override
  bool operator ==(Object other) =>
      other is SignalTarget &&
      other.sessionId == sessionId &&
      other.targetGeneration == targetGeneration &&
      other.provider == provider &&
      other.intersectionKey == intersectionKey &&
      other.approachKey == approachKey &&
      other.catalogVersion == catalogVersion &&
      other.movement == movement;

  @override
  int get hashCode => Object.hash(sessionId, targetGeneration, provider,
      intersectionKey, approachKey, catalogVersion, movement);
}

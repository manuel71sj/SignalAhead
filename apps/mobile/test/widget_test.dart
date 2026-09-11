import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/main.dart';

void main() {
  testWidgets('first screen does not start location tracking', (tester) async {
    await tester.pumpWidget(const SignalAheadApp());

    expect(find.text('SignalAhead'), findsOneWidget);
    expect(find.textContaining('위치 권한을 요청하지 않습니다'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}

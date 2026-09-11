import 'package:flutter/material.dart';

void main() {
  runApp(const SignalAheadApp());
}

class SignalAheadApp extends StatelessWidget {
  const SignalAheadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignalAhead',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF16A34A)),
        useMaterial3: true,
      ),
      home: const PreDriveScreen(),
    );
  }
}

class PreDriveScreen extends StatelessWidget {
  const PreDriveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.traffic, size: 72),
                SizedBox(height: 24),
                Text(
                  'SignalAhead',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 12),
                Text(
                  '주행을 시작하기 전입니다. 시작 버튼을 누르기 전에는 위치 권한을 요청하지 않습니다.',
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 32),
                FilledButton(onPressed: null, child: Text('주행 시작 준비 중')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

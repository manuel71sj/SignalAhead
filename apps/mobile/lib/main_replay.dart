import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'driving/driving_pipeline.dart';
import 'features/driving/presentation/driving_content.dart';
import 'location/location_sample.dart';
import 'prediction/prediction.dart';
import 'signals/signal_stream.dart';
import 'signals/signal_target.dart';

/// Invoke explicitly with -t lib/main_replay.dart. Never imported by main.dart.
void main() {
  if (!kDebugMode) throw UnsupportedError('Synthetic replay is debug-only');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    title: 'SignalAhead — 합성 개발 리플레이',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF69DBB6), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF101B26),
        useMaterial3: true),
    home: const ReplayScreen(),
  ));
}

class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key});
  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen>
    with WidgetsBindingObserver {
  final _http = http.Client();
  final _clock = Stopwatch()..start();
  late final Uri _base;
  DrivingPipeline? _pipeline;
  List<Map<String, dynamic>> _scenes = [];
  Map<String, dynamic>? _selected;
  String _selectedId = 'possible';
  String? _error;
  Timer? _locationTimer;
  int _generation = 0;
  bool _busy = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    const configured = String.fromEnvironment('REPLAY_BASE_URL');
    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : '127.0.0.1';
    _base = Uri.parse(configured.isEmpty ? 'http://$host:3090' : configured);
    if (_base.scheme != 'http' ||
        !_base.hasAuthority ||
        _base.userInfo.isNotEmpty ||
        !const ['localhost', '127.0.0.1', '10.0.2.2'].contains(_base.host)) {
      _error = '개발 리플레이는 로컬 서버만 연결합니다.';
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final response = await _http
          .get(_base.resolve('/__replay'))
          .timeout(const Duration(seconds: 5));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || data['origin'] != 'synthetic') {
        throw const FormatException('Not a replay server');
      }
      if (!mounted) return;
      setState(() {
        _scenes = (data['scenes'] as List).cast<Map<String, dynamic>>();
        _error = null;
      });
    } on Exception {
      if (mounted) {
        setState(() {
          _error = '로컬 합성 리플레이 서버에 연결할 수 없습니다. 서버를 실행한 뒤 다시 시도하세요.';
        });
      }
    }
  }

  Future<void> _play(String id) async {
    final generation = ++_generation;
    _locationTimer?.cancel();
    _pipeline?.removeListener(_changed);
    _pipeline?.dispose();
    _pipeline = null;
    setState(() {
      _busy = true;
      _error = null;
      _selectedId = id;
    });
    try {
      final response = await _http
          .post(_base.resolve('/__replay/select/$id'))
          .timeout(const Duration(seconds: 5));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || data['origin'] != 'synthetic') {
        throw const FormatException('Not a replay scene');
      }
      if (!mounted || generation != _generation) return;
      final policyData = data['policy'] as Map<String, dynamic>;
      final policy = PredictionPolicy.syntheticFixture(
        maxSignalAgeMs: policyData['maxSignalAgeMs'] as int,
        clockSkewBudgetMs: policyData['clockSkewBudgetMs'] as int,
        minimumSpeedMps: (policyData['minimumSpeedMps'] as num).toDouble(),
        maxHorizontalAccuracyM:
            (policyData['maxHorizontalAccuracyM'] as num).toDouble(),
        extraSafetyMarginMs: policyData['extraSafetyMarginMs'] as int,
      );
      final pipeline = DrivingPipeline(
        signals: SignalStreamController(
            baseUri: _base,
            policy: policy,
            monotonicNow: () => _clock.elapsedMilliseconds,
            syntheticFixture: true),
        policy: policy,
        monotonicNow: () => _clock.elapsedMilliseconds,
        synthetic: true,
      );
      _pipeline = pipeline;
      _selected = data;
      pipeline.addListener(_changed);
      pipeline.start(data['sessionId'] as String);
      pipeline.setForeground(_foreground);
      await _injectLocation();
      if (!mounted || generation != _generation) return;
      _locationTimer = Timer.periodic(const Duration(milliseconds: 500),
          (_) => unawaited(_injectLocation()));
    } on Exception {
      if (mounted && generation == _generation) {
        _pipeline?.stop();
        _error = '리플레이 연결 실패 — 실제 신호로 대체하지 않습니다.';
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _injectLocation() async {
    final data = _selected;
    final pipeline = _pipeline;
    if (!_foreground || pipeline == null || !pipeline.active || data == null) {
      return;
    }
    final scene = data['scene'] as Map<String, dynamic>;
    final target = data['target'] as Map<String, dynamic>;
    final minSpeed = (scene['speedMinMps'] as num).toDouble();
    final maxSpeed = (scene['speedMaxMps'] as num).toDouble();
    // Authored simulator input, not a platform sensor or real road geometry.
    await pipeline.update(
      location: LocationSample(
          sessionId: data['sessionId'] as String,
          latitude: 37.5231,
          longitude: 126.9709,
          horizontalAccuracyM: 5,
          speedMps: (minSpeed + maxSpeed) / 2,
          speedAccuracyMps: (maxSpeed - minSpeed) / 2,
          courseDeg: maxSpeed == 0 ? null : 90,
          courseAccuracyDeg: 4,
          measuredAtUtcMs: DateTime.now().millisecondsSinceEpoch,
          deviceReceivedMonotonicMs: _clock.elapsedMilliseconds),
      target: scene['ambiguous'] == true
          ? null
          : SignalTarget(
              sessionId: target['sessionId'] as String,
              targetGeneration: target['targetGeneration'] as int,
              provider: target['provider'] as String,
              intersectionKey: target['intersectionKey'] as String,
              approachKey: target['approachKey'] as String,
              catalogVersion: target['catalogVersion'] as String,
            ),
      distanceM: NumericInterval(
          min: (scene['distanceMinM'] as num).toDouble(),
          max: (scene['distanceMaxM'] as num).toDouble()),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _pipeline?.setForeground(_foreground);
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _locationTimer?.cancel();
    _pipeline?.removeListener(_changed);
    _pipeline?.dispose();
    _http.close();
    _clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('합성 리플레이',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            bottom: MediaQuery.sizeOf(context).width >= 360 &&
                    MediaQuery.textScalerOf(context).scale(12) <= 18
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(24),
                    child: Text(
                        '개발 연결: ${_pipeline?.signals.unavailableReason ?? (_pipeline == null ? '대기' : '연결됨')}',
                        maxLines: 1,
                        style: const TextStyle(fontSize: 12)))
                : null,
            actions: [
              PopupMenuButton<String>(
                  tooltip: '개발 시나리오 선택',
                  enabled: !_busy,
                  initialValue: _selectedId,
                  onSelected: (id) => unawaited(_play(id)),
                  itemBuilder: (_) => _scenes
                      .map((scene) => PopupMenuItem<String>(
                          value: scene['id'] as String,
                          child: Text(scene['label'] as String)))
                      .toList()),
            ]),
        body: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!),
                          const SizedBox(height: 16),
                          FilledButton(
                              onPressed: () => unawaited(_load()),
                              child: const Text('서버 다시 연결')),
                        ])))
                : _pipeline != null
                    ? DrivingContent(
                        data: _pipeline!.view,
                        onStartStop: () {
                          if (_pipeline!.active) {
                            _locationTimer?.cancel();
                            _pipeline!.stop();
                          } else {
                            unawaited(_play(_selectedId));
                          }
                        })
                    : Center(
                        child: FilledButton(
                            onPressed: _scenes.isEmpty
                                ? null
                                : () => unawaited(_play(_selectedId)),
                            child: const Text('합성 리플레이 시작'))),
      );
}

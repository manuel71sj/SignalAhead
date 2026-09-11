import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'drive_session/drive_session_state.dart';
import 'driving/driving_view_data.dart';
import 'features/driving/presentation/driving_content.dart';
import 'location/location_gateway.dart';
import 'signals/catalog_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SignalAheadApp());
}

class SignalAheadApp extends StatelessWidget {
  const SignalAheadApp({super.key, this.controller});
  final DriveSessionController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SignalAhead',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF69DBB6),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF101B26),
          useMaterial3: true,
        ),
        home: DriveScreen(controller: controller),
      );
}

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, this.controller});
  final DriveSessionController? controller;
  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with WidgetsBindingObserver {
  late final DriveSessionController controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    const rawUrl = String.fromEnvironment('API_BASE_URL');
    final uri = Uri.tryParse(rawUrl);
    final localHost = uri != null &&
        const ['localhost', '127.0.0.1', '10.0.2.2'].contains(uri.host);
    final configured = uri != null &&
        uri.hasAuthority &&
        uri.userInfo.isEmpty &&
        (uri.scheme == 'https' ||
            (kDebugMode && localHost && uri.scheme == 'http'));
    controller = widget.controller ??
        DriveSessionController(
          location: PlatformLocationGateway(),
          createCatalogClient: () => HttpCatalogClient(configured ? uri : null),
          signalBaseUri: configured ? uri : null,
        );
    controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.setForeground(
      state == AppLifecycleState.resumed,
      permissionDialog: state == AppLifecycleState.inactive,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  String get _message {
    final blocker = controller.blocker;
    if (blocker != null) {
      return switch (blocker) {
        LocationBlocker.permissionDenied =>
          '위치 권한이 거부되었습니다. 시작을 눌러 다시 요청할 수 있습니다.',
        LocationBlocker.permissionDeniedForever =>
          '위치 권한이 꺼져 있습니다. 설정에서 앱 사용 중 위치 권한을 허용해 주세요.',
        LocationBlocker.preciseLocationOff =>
          '정확한 위치가 꺼져 있습니다. 설정에서 정확한 위치를 허용해 주세요.',
        LocationBlocker.serviceOff => '기기의 위치 서비스가 꺼져 있습니다. 위치 서비스를 켜 주세요.',
        LocationBlocker.staleLocation =>
          '새 위치를 기다리는 중입니다. 오래된 위치로 신호를 선택하지 않습니다.',
        LocationBlocker.sensorError =>
          '위치를 가져오지 못했습니다. 위치 설정을 확인한 뒤 다시 시작해 주세요.',
      };
    }
    return switch (controller.phase) {
      DriveSessionPhase.idle ||
      DriveSessionPhase.stopped =>
        '주행 시작 전에는 위치 권한을 요청하지 않습니다. 위치는 전경 주행 중에만 사용합니다.',
      DriveSessionPhase.requestingPermission => '위치 권한을 확인하고 있습니다.',
      DriveSessionPhase.acquiringLocation =>
        '현재 위치를 확인하고 있습니다. 하늘이 보이는 곳에서 잠시 기다려 주세요.',
      DriveSessionPhase.paused =>
        '주행이 일시 정지되었습니다. 새 위치와 신호를 확인하기 전에는 예측을 표시하지 않습니다.',
      DriveSessionPhase.driving => switch (controller.coverage.status) {
          CoverageStatus.checking => '주변의 검증된 지원 구간을 확인하고 있습니다.',
          CoverageStatus.supported =>
            '진행 도로와 정지선을 확인하고 있습니다. 방향이 확정되면 현재 신호를 구독합니다.',
          CoverageStatus.unsupported =>
            '이 주변에는 검증된 지원 구간이 없습니다. 신호와 도달 예측을 표시하지 않습니다.',
          CoverageStatus.geometryUnavailable =>
            '도로·방향·정지선 정보가 충분하지 않습니다. 가까운 교차로를 임의로 선택하지 않습니다.',
          CoverageStatus.offline =>
            '서버에 연결할 수 없습니다. 이전 신호를 표시하지 않으며 연결을 다시 확인합니다.',
          CoverageStatus.notConfigured =>
            '신호 서버가 설정되지 않았습니다. 위치 상태만 표시하며 신호 예측은 비활성화됩니다.',
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    final sample = controller.sample;
    final active = controller.running ||
        controller.phase == DriveSessionPhase.requestingPermission ||
        controller.phase == DriveSessionPhase.paused;
    final phaseLabel = switch (controller.phase) {
      DriveSessionPhase.idle => '주행 전',
      DriveSessionPhase.stopped => '주행 종료',
      DriveSessionPhase.requestingPermission => '권한 확인',
      DriveSessionPhase.acquiringLocation => '위치 확인',
      DriveSessionPhase.driving => '주행 중',
      DriveSessionPhase.paused => '일시 정지',
    };
    final title = !active
        ? '주행을 시작할까요?'
        : controller.coverage.status == CoverageStatus.offline
            ? '연결 확인 필요'
            : sample == null
                ? '위치 확인 중'
                : '지원 정보 없음';
    return Scaffold(
      appBar: AppBar(
          title: const Text('SignalAhead'),
          backgroundColor: Colors.transparent),
      body: DrivingContent(
        data: controller.drivingView ??
            DrivingViewData(
              active: active,
              phaseLabel: phaseLabel,
              heading: title,
              message: _message,
              speedMps: sample?.speedMps,
              horizontalAccuracyM: sample?.horizontalAccuracyM,
            ),
        onStartStop: active ? controller.stop : () => controller.start(),
        onOpenSettings: controller.blocker != null && !kIsWeb
            ? controller.location.openSettings
            : null,
      ),
    );
  }
}

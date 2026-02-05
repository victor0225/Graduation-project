import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math';
import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MaterialApp(home: BluetoothApp()));
}

class KalmanFilter {
  double _processNoise = 0.1; // 시스템 소음 (값이 작을수록 예측 모델을 신뢰)
  double _measurementNoise = 0.5; // 측정 소음 (값이 작을수록 센서값을 신뢰)
  double _estimatedValue = 0.0; // 추정된 값
  double _errorCovariance = 1.0; // 오차 공분산

  KalmanFilter(this._processNoise, this._measurementNoise, this._estimatedValue);

  double filter(double measurement) {
    // 1. 예측 (Prediction)
    // 현재 상태 유지 (정적 모델 가정)
    _errorCovariance = _errorCovariance + _processNoise; // 1.1

    // 2. 보정 (Update) - 칼만 이득 계산
    double kalmanGain = _errorCovariance / (_errorCovariance + _measurementNoise); // 1.1 / 1.6 = 0.6875
    
    // 추정치 업데이트
    _estimatedValue = _estimatedValue + kalmanGain * (measurement - _estimatedValue); // 0.6875 * (-55.0 - 0.0) = -37.8125
    
    // 오차 공분산 업데이트
    _errorCovariance = (1 - kalmanGain) * _errorCovariance;

    return _estimatedValue;
  }
}

class BluetoothApp extends StatefulWidget {
  const BluetoothApp({super.key});

  @override
  State<BluetoothApp> createState() => _BluetoothAppState();
}

class _BluetoothAppState extends State<BluetoothApp> {
  // --- 상태 변수 ---
  Offset userPosition = const Offset(200, 200); // 사용자의 시작 위치 고정
  int _stepCount = 0;
  double _userHeading = 0.0;
  bool _isStepDetected = false;
  bool _isPdrActive = false; // PDR 활성화 상태 플래그

  // 칼만 필터 인스턴스 (비콘 3개용)
  final KalmanFilter _kfRssi1 = KalmanFilter(0.1, 1.0, -60.0);
  final KalmanFilter _kfRssi2 = KalmanFilter(0.1, 1.0, -60.0);
  final KalmanFilter _kfRssi3 = KalmanFilter(0.1, 1.0, -60.0);

  // --- 센서 및 구독 관리 ---
  StreamSubscription? _accelSubscription;
  StreamSubscription? _magSubscription;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // --- 설정값 ---
  final double _stepThreshold = 13.0;
  final double _stepLength = 15.0;
  final List<Map<String, dynamic>> beacons = [
    {'id': 'B1', 'pos': const Offset(100, 100)},
    {'id': 'B2', 'pos': const Offset(200, 100)},
    {'id': 'B3', 'pos': const Offset(240, 170)},
  ];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
  }

  double rssiToDistance(int rssi) {
  // [파라미터 설정]
  // txPower: 비콘으로부터 1m 거리에서 측정된 RSSI 값 (비콘 제조사마다 다름, 보통 -59에서 -65 사이)
  // n: 환경 지수 (장애물이 없는 실내는 2.0, 벽이 많으면 3.0~4.0)
    const int txPower = -60; 
    const double n = 2.0;

    if (rssi == 0) {
      return -1.0; // 신호를 측정할 수 없는 경우
    }

    // 공식: d = 10 ^ ((txPower - RSSI) / (10 * n))
    return pow(10, (txPower - rssi) / (10 * n)).toDouble();
  }

  // --- 1. RSSI 삼각측량 연산 버튼 로직 ---
  void _calculateByRssi() {
    // 측정된 생(Raw) 데이터 (더미값)
    double rawR1 = -55.0;
    double rawR2 = -68.0;
    double rawR3 = -62.0;

    // 칼만 필터 적용
    double filteredR1 = _kfRssi1.filter(rawR1);
    double filteredR2 = _kfRssi2.filter(rawR2);
    double filteredR3 = _kfRssi3.filter(rawR3);

    // 필터링된 RSSI를 거리로 변환하여 삼변측량 수행
    double d1 = rssiToDistance(filteredR1.toInt());
    double d2 = rssiToDistance(filteredR2.toInt());
    double d3 = rssiToDistance(filteredR3.toInt());
    
    setState(() {
      userPosition = _trilateration(d1 * 100, d2 * 100, d3 * 100);
    });
    //print("칼만 필터 적용 완료! 원본: $rawR1 -> 필터: $filteredR1");
  }

  Offset _trilateration(double d1, double d2, double d3) {
    double b1x = 100, b1y = 100, b2x = 200, b2y = 100, b3x = 240, b3y = 170;
    double A = 2 * (b2x - b1x);
    double B = 2 * (b2y - b1y);
    double C = pow(d1, 2).toDouble() - pow(d2, 2).toDouble() - pow(b1x, 2).toDouble() + pow(b2x, 2).toDouble() - pow(b1y, 2).toDouble() + pow(b2y, 2).toDouble();
    double D = 2 * (b3x - b2x);
    double E = 2 * (b3y - b2y);
    double F = pow(d2, 2).toDouble() - pow(d3, 2).toDouble() - pow(b2x, 2).toDouble() + pow(b3x, 2).toDouble() - pow(b2y, 2).toDouble() + pow(b3y, 2).toDouble();
    double x = (C * E - F * B) / (A * E - D * B);
    double y = (A * F - D * C) / (A * E - D * B);
    return Offset(x, y);
  }

  // --- 2. PDR & 지자기 활성화 버튼 로직 ---
  void _togglePdr() {
    setState(() {
      _isPdrActive = !_isPdrActive;
      if (_isPdrActive) {
        _startPDR();
        _startHeadingTracking();
      } else {
        _accelSubscription?.cancel();
        _magSubscription?.cancel();
      }
    });
  }

  void _startPDR() {
    _accelSubscription = accelerometerEventStream().listen((event) {
      double magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (magnitude > _stepThreshold && !_isStepDetected) {
        setState(() {
          _isStepDetected = true;
          _stepCount++;
          // 현재 방향으로 이동
          double newX = userPosition.dx + _stepLength * cos(_userHeading);
          double newY = userPosition.dy + _stepLength * sin(_userHeading);
          userPosition = Offset(newX, newY);
        });
      } else if (magnitude < _stepThreshold - 2.0) {
        _isStepDetected = false;
      }
    });
  }

  void _startHeadingTracking() {
    _magSubscription = magnetometerEventStream().listen((event) {
      setState(() {
        _userHeading = atan2(event.y, event.x);
      });
    });
  }

  // --- 3. Firebase 전송 버튼 ---
  Future<void> _sendToFirebase() async {
    try {
      await _firestore.collection('user_locations').add({
        'x': userPosition.dx,
        'y': userPosition.dy,
        'step_count': _stepCount,
        'timestamp': FieldValue.serverTimestamp(),
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("DB 전송 성공!")));
    } catch (e) {
      //print("전송 에러: $e");
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _magSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Indoor Tracking")),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: InteractiveViewer(
              child: Stack(
                children: [
                  Image.asset('assets/map_one.png', fit: BoxFit.contain),
                  ...beacons.map((b) => Positioned(
                    left: b['pos'].dx, top: b['pos'].dy,
                    child: Image.asset('assets/Beacon_G.png', width: 30))),
                  Positioned(
                    left: userPosition.dx, top: userPosition.dy,
                    child: Column(
                      children: [
                        Image.asset('assets/User_B.png', width: 40),
                        Text("걸음: $_stepCount", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      ],
                    )),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ElevatedButton(
                  onPressed: _calculateByRssi,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  child: const Text("1. RSSI 연산"),
                ),
                ElevatedButton(
                  onPressed: _togglePdr,
                  style: ElevatedButton.styleFrom(backgroundColor: _isPdrActive ? Colors.red : Colors.orange),
                  child: Text(_isPdrActive ? "PDR 중지" : "2. PDR 시작"),
                ),
                ElevatedButton(
                  onPressed: _sendToFirebase,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text("3. DB 전송"),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
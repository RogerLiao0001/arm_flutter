import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../logic/arm_controller.dart';
import '../services/mqtt_service.dart';

final mqttServiceProvider = Provider<MqttService>((ref) {
  return MqttService(
    broker: '178.128.54.195', // 請確認您的伺服器 IP 或網域名稱
    port: 1883,              // Mosquitto 預設連線埠號
    clientId: 'flutter_app', // 自定義 clientId
    // 如有帳號密碼，可設定：username: 'xxx', password: 'xxx'
  );
});

final armControllerProvider = Provider<ArmController>((ref) {
  final mqttService = ref.watch(mqttServiceProvider);
  final controller = ArmController(mqttService: mqttService);
  // 初始化 8 顆馬達
  controller.initializeServos([
    Servo(id: 1, name: 'Base', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 2, name: 'Shoulder', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 3, name: 'Elbow', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 4, name: 'Claw', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 5, name: 'Extra1', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 6, name: 'Extra2', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 7, name: 'Extra3', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
    Servo(id: 8, name: 'Extra4', minAngle: 0.0, maxAngle: 180.0, currentAngle: 90.0),
  ]);
  return controller;
});

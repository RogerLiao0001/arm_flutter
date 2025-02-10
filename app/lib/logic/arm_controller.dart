import '../services/mqtt_service.dart';

/// 表示單一伺服馬達的基本資訊
class Servo {
  final int id;
  final String name;
  final double minAngle;
  final double maxAngle;
  double currentAngle;

  Servo({
    required this.id,
    required this.name,
    required this.minAngle,
    required this.maxAngle,
    this.currentAngle = 90.0,
  });

  /// 設定角度，並限制在 minAngle 與 maxAngle 之間
  void setAngle(double angle) {
    if (angle < minAngle) {
      currentAngle = minAngle;
    } else if (angle > maxAngle) {
      currentAngle = maxAngle;
    } else {
      currentAngle = angle;
    }
  }
}

/// 控制整組馬達的邏輯層
class ArmController {
  final MqttService mqttService;
  List<Servo> servos = [];

  ArmController({required this.mqttService});

  /// 初始化馬達清單（未來可擴充至更多馬達）
  void initializeServos(List<Servo> servoList) {
    servos = servoList;
  }

  /// 更新指定馬達角度並發佈 MQTT 指令
  void setServoAngle(int id, double angle) {
    final servo = servos.firstWhere(
      (s) => s.id == id,
      orElse: () => throw Exception("Servo id $id not found"),
    );
    servo.setAngle(angle);
    // 以 JSON 格式傳送命令，方便後端解析
    final command = '{"id": ${servo.id}, "angle": ${servo.currentAngle}}';
    mqttService.publish("servo/${servo.id}", command);
  }

  /// 同時設定多顆馬達（key: servo id, value: angle）
  void setMultipleServoAngles(Map<int, double> angles) {
    angles.forEach((id, angle) {
      setServoAngle(id, angle);
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:mqtt_client/mqtt_client.dart';
import '../providers/arm_controller_provider.dart';
import '../logic/arm_controller.dart';

class MotorControlPage extends ConsumerStatefulWidget {
  const MotorControlPage({Key? key}) : super(key: key);
  @override
  ConsumerState<MotorControlPage> createState() => _MotorControlPageState();
}

class _MotorControlPageState extends ConsumerState<MotorControlPage> {
  // 設定更新閥值與增量係數
  final double threshold = 0.1;
  final double factor = 2.0; // 每次累加約 2 度

  @override
  void initState() {
    super.initState();
    // 啟動時連線 MQTT
    Future.microtask(() {
      final mqttService = ref.read(mqttServiceProvider);
      mqttService.connect();
    });
  }

  /// 建立一個 Joystick 控制組件，
  /// [label] 為顯示用的文字，
  /// [servoX] 為 X 軸對應的馬達 id，
  /// [servoY] 為 Y 軸對應的馬達 id。
  Widget buildJoystick(
    String label, {
    required int servoX,
    required int servoY,
    required ArmController armController,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Container(
          width: 100,
          height: 100,
          child: Joystick(
            mode: JoystickMode.all,
            listener: (details) {
              // 若 X 軸有明顯變化，則累加更新 servoX
              if (details.x.abs() > threshold) {
                final servo = armController.servos.firstWhere((s) => s.id == servoX);
                double newAngle = servo.currentAngle + details.x * factor;
                armController.setServoAngle(servoX, newAngle);
              }
              // 若 Y 軸有明顯變化，則累加更新 servoY
              if (details.y.abs() > threshold) {
                final servo = armController.servos.firstWhere((s) => s.id == servoY);
                double newAngle = servo.currentAngle + details.y * factor;
                armController.setServoAngle(servoY, newAngle);
              }
              setState(() {});
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final armController = ref.watch(armControllerProvider);
    final mqttService = ref.watch(mqttServiceProvider);
    String connectionStatus = (mqttService.connectionState == MqttConnectionState.connected)
        ? "Connected"
        : "Disconnected";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Motor Control"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Reconnect MQTT",
            onPressed: () {
              mqttService.connect();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // MQTT 連線狀態顯示
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey[200],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("MQTT Status: ", style: TextStyle(fontSize: 16)),
                Text(
                  connectionStatus,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          // 上半部：Video Stream Placeholder (flex=3 => 更大)
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              color: Colors.black12,
              child: Center(
                child: Text(
                  "Video Stream Placeholder",
                  style: TextStyle(fontSize: 24, color: Colors.grey[700]),
                ),
              ),
            ),
          ),
          // Joystick 區域 (flex=5)
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  // 在第一排 Joystick 前多留一點空間，讓他們更靠下
                  const SizedBox(height: 20),

                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Joystick 1: 控制 Servo 1 (X) 與 Servo 3 (Y)
                        buildJoystick(
                          "Main Left\n(Servo 1 / Servo 3)",
                          servoX: 1,
                          servoY: 3,
                          armController: armController,
                        ),
                        // Joystick 2: 控制 Servo 2 (X) 與 Servo 4 (Y)
                        buildJoystick(
                          "Main Right\n(Servo 2 / Servo 4)",
                          servoX: 2,
                          servoY: 4,
                          armController: armController,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Joystick 3: 控制 Servo 5 (X) 與 Servo 7 (Y)
                        buildJoystick(
                          "Backup Left\n(Servo 5 / Servo 7)",
                          servoX: 5,
                          servoY: 7,
                          armController: armController,
                        ),
                        // Joystick 4: 控制 Servo 6 (X) 與 Servo 8 (Y)
                        buildJoystick(
                          "Backup Right\n(Servo 6 / Servo 8)",
                          servoX: 6,
                          servoY: 8,
                          armController: armController,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      backgroundColor: Colors.blueGrey[50],
    );
  }
}

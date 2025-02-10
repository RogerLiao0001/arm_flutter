import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:mqtt_client/mqtt_client.dart'; // 用於取得連線狀態
import '../providers/arm_controller_provider.dart';
import '../logic/arm_controller.dart'; // 取得 ArmController 類型
import 'package:mqtt_client/mqtt_server_client.dart';

// ----------------------------------------------------------------------
// 這裡建立一個獨立的 widget，用於接收雲端 MQTT 影像串流並顯示
// ----------------------------------------------------------------------
class MqttVideoStreamWidget extends StatefulWidget {
  final String broker;
  final int port;
  final String topic;
  const MqttVideoStreamWidget({
    Key? key,
    required this.broker,
    required this.port,
    required this.topic,
  }) : super(key: key);

  @override
  _MqttVideoStreamWidgetState createState() => _MqttVideoStreamWidgetState();
}

class _MqttVideoStreamWidgetState extends State<MqttVideoStreamWidget> {
  MqttServerClient? client;
  Uint8List? latestImage;
  bool connected = false;

  @override
  void initState() {
    super.initState();
    connect();
  }

  Future<void> connect() async {
    client = MqttServerClient(widget.broker, "flutter_video_client");
    client!.port = widget.port;
    client!.logging(on: true);
    client!.keepAlivePeriod = 20;
    client!.onDisconnected = onDisconnected;
    client!.onConnected = onConnected;
    client!.onSubscribed = onSubscribed;
    final connMess = MqttConnectMessage()
        .withClientIdentifier("flutter_video_client")
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    client!.connectionMessage = connMess;
    try {
      await client!.connect();
    } catch (e) {
      print("MQTT video connect exception: $e");
      disconnect();
    }
  }

  void disconnect() {
    client?.disconnect();
    setState(() {
      connected = false;
    });
  }

  void onConnected() {
    print("Video MQTT Connected");
    setState(() {
      connected = true;
    });
    client!.subscribe(widget.topic, MqttQos.atLeastOnce);
    client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (var message in messages) {
        if (message.topic == widget.topic) {
          final recMess = message.payload as MqttPublishMessage;
          final payload = recMess.payload.message;
          setState(() {
            latestImage = Uint8List.fromList(payload);
          });
        }
      }
    });
  }

  void onDisconnected() {
    print("Video MQTT Disconnected");
    setState(() {
      connected = false;
    });
  }

  void onSubscribed(String topic) {
    print("Subscribed to video topic: $topic");
  }

  @override
  void dispose() {
    client?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (latestImage != null) {
      return Image.memory(latestImage!, fit: BoxFit.cover);
    } else {
      return const Center(child: CircularProgressIndicator());
    }
  }
}

// ----------------------------------------------------------------------
// 以下為主頁面，包含馬達控制與影像串流整合
// ----------------------------------------------------------------------
class MotorControlPage extends ConsumerStatefulWidget {
  const MotorControlPage({Key? key}) : super(key: key);
  @override
  ConsumerState<MotorControlPage> createState() => _MotorControlPageState();
}

class _MotorControlPageState extends ConsumerState<MotorControlPage> {
  final double threshold = 0.1;
  final double factor = 2.0;
  // 這裡用 _cameraUrl 作為參考（用於編輯），但實際影像來源來自 MQTT 串流 widget
  String _cameraUrl = "http://192.168.102.65/stream"; 

  Future<void> _editCameraUrl() async {
    TextEditingController controller = TextEditingController(text: _cameraUrl);
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("設定串流 URL"),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: "Camera Stream URL",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("取消"),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _cameraUrl = controller.text.trim();
                });
                Navigator.of(context).pop();
              },
              child: const Text("確定"),
            ),
          ],
        );
      },
    );
  }

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
              if (details.x.abs() > threshold) {
                final servo = armController.servos.firstWhere((s) => s.id == servoX);
                double newAngle = servo.currentAngle + details.x * factor;
                armController.setServoAngle(servoX, newAngle);
              }
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
  void initState() {
    super.initState();
    Future.microtask(() {
      final mqttService = ref.read(mqttServiceProvider);
      mqttService.connect();
    });
  }

  @override
  Widget build(BuildContext context) {
    final armController = ref.watch(armControllerProvider);
    final mqttService = ref.watch(mqttServiceProvider);
    String connectionStatus =
        (mqttService.connectionState == MqttConnectionState.connected) ? "Connected" : "Disconnected";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Motor Control"),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: "編輯串流 URL",
            onPressed: _editCameraUrl,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "重新連線 MQTT",
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
                Text(connectionStatus,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          // 上半部：改為使用 MqttVideoStreamWidget 顯示雲端傳來的影像
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: MqttVideoStreamWidget(
                broker: "178.128.54.195",
                port: 1883,
                topic: "esp32cam/stream",
              ),
            ),
          ),
          // 下半部：4 個 Joystick 區域（2x2 格狀排列）
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        buildJoystick("Main Left\n(Servo 1 / Servo 3)",
                            servoX: 1, servoY: 3, armController: armController),
                        buildJoystick("Main Right\n(Servo 2 / Servo 4)",
                            servoX: 2, servoY: 4, armController: armController),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        buildJoystick("Backup Left\n(Servo 5 / Servo 7)",
                            servoX: 5, servoY: 7, armController: armController),
                        buildJoystick("Backup Right\n(Servo 6 / Servo 8)",
                            servoX: 6, servoY: 8, armController: armController),
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

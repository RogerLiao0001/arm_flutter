import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mqtt_client/mqtt_client.dart' show MqttConnectionState;
import '../providers/arm_controller_provider.dart';
import '../logic/arm_controller.dart';

/// LiveKit 影像接收 Widget（僅接收，不發送）
class LiveKitReceiverWidget extends StatefulWidget {
  final String url;
  final String token;
  const LiveKitReceiverWidget({Key? key, required this.url, required this.token})
      : super(key: key);

  @override
  _LiveKitReceiverWidgetState createState() => _LiveKitReceiverWidgetState();
}

class _LiveKitReceiverWidgetState extends State<LiveKitReceiverWidget> {
  Room? _room;
  RemoteVideoTrack? _videoTrack;

  @override
  void initState() {
    super.initState();
    _connectRoom();
  }

  Future<void> _connectRoom() async {
    try {
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      // 加速連線（可選）
      await room.prepareConnection(widget.url, widget.token);
      await room.connect(widget.url, widget.token);
      print('Connected to room: ${room.name}');

      // 當房間狀態變更時更新 UI
      room.addListener(() {
        setState(() {});
      });

      // 如果房間中已有遠端參與者，直接取第一個視頻軌道
      for (final participant in room.remoteParticipants.values) {
        for (final pub in participant.trackPublications.values) {
          if (pub.track != null && pub.track is RemoteVideoTrack) {
            print('Found existing video track from: ${participant.identity}');
            setState(() {
              _videoTrack = pub.track as RemoteVideoTrack;
            });
          }
        }
      }
      setState(() {
        _room = room;
      });
    } catch (e) {
      print('Connection error: $e');
    }
  }

  @override
  void dispose() {
    _room?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _videoTrack != null
        ? VideoTrackRenderer(_videoTrack!)
        : Container(
            color: Colors.black,
            child: const Center(
              child: Text(
                'Waiting for stream...(Click setting to reload)',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
          );
  }
}

/// 主頁面：包含 LiveKit 影像串流、MQTT 狀態與馬達控制部分（不動）
class MotorControlPage extends ConsumerStatefulWidget {
  const MotorControlPage({Key? key}) : super(key: key);

  @override
  ConsumerState<MotorControlPage> createState() => _MotorControlPageState();
}

class _MotorControlPageState extends ConsumerState<MotorControlPage> {
  // 將 LiveKit 參數改為可變變數，便於後續修改
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  String livekitToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJuYW1lIjoid2ViLXJlY2VpdmVyIiwidmlkZW8iOnsicm9vbUpvaW4iOnRydWUsInJvb20iOiJteS1yb29tIiwiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuU3Vic2NyaWJlIjp0cnVlLCJjYW5QdWJsaXNoRGF0YSI6dHJ1ZX0sInN1YiI6IndlYi1yZWNlaXZlciIsImlzcyI6IkFQSVQ1OFd5enFQN1hQTSIsIm5iZiI6MTc0MzAxMzMyMiwiZXhwIjoxNzQzMDM0OTIyfQ.h_uOZZheRgoCk4cMNSj3dQI9lksT1S9O0tyYSSOA_ro';

  // 重新生成 LiveKitReceiverWidget 的 key
  Key _receiverKey = UniqueKey();

  // 馬達控制部分
  double _sliderVal1 = 90;
  double _sliderVal2 = 90;
  double _sliderVal3 = 90;
  double _sliderVal4 = 90;
  double _sliderVal5 = 90;
  bool _isElectromagnetOn = false;

  // 開啟設定對話框以修改 LiveKit 參數
  Future<void> _editStreamingSettings() async {
    TextEditingController urlController = TextEditingController(text: livekitUrl);
    TextEditingController tokenController = TextEditingController(text: livekitToken);
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("修改串流設定"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: "LiveKit URL",
                ),
              ),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  labelText: "LiveKit Token",
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("取消"),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  livekitUrl = urlController.text.trim();
                  livekitToken = tokenController.text.trim();
                  // 更新 key 以刷新 LiveKitReceiverWidget
                  _receiverKey = UniqueKey();
                });
                Navigator.of(context).pop();
              },
              child: const Text("儲存"),
            ),
          ],
        );
      },
    );
  }

  // 建立單個垂直滑桿小部件
  Widget _buildServoSlider({
    required String label,
    required int servoId,
    required double currentValue,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        RotatedBox(
          quarterTurns: -1,
          child: Slider(
            value: currentValue,
            min: 0,
            max: 180,
            divisions: 180,
            label: "${currentValue.toInt()}°",
            onChanged: onChanged,
          ),
        ),
        Text("${currentValue.toInt()}°"),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final armController = ref.watch(armControllerProvider);
    final mqttService = ref.watch(mqttServiceProvider);
    final connectionState = mqttService.connectionState;
    String connectionStatus = (connectionState == MqttConnectionState.connected)
        ? "Connected"
        : "Disconnected";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Motor Control"),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "修改串流設定",
            onPressed: _editStreamingSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // 上半部：使用 LiveKitReceiverWidget 接收影像串流
          Expanded(
            flex: 3,
            child: Container(
              key: _receiverKey, // 用於刷新連線
              width: double.infinity,
              color: Colors.black,
              child: LiveKitReceiverWidget(url: livekitUrl, token: livekitToken),
            ),
          ),
          // 中間：MQTT 狀態顯示與重新連線按鈕
          Container(
            height: 60,
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text("MQTT Status: $connectionStatus",
                    style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 20),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: "重新連線 MQTT",
                  onPressed: () {
                    // 重新連線前先斷線
                    mqttService.disconnect();
                    mqttService.connect();
                  },
                ),
              ],
            ),
          ),
          // 下半部：電磁帖開關與馬達控制
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text("electromagnet: "),
                        Switch(
                          value: _isElectromagnetOn,
                          onChanged: (bool value) {
                            setState(() {
                              _isElectromagnetOn = value;
                            });
                            mqttService.publish("servo/electromagnet", value ? "ON" : "OFF");
                          },
                        ),
                        Text(_isElectromagnetOn ? "On" : "Off"),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildServoSlider(
                          label: "Servo 1",
                          servoId: 1,
                          currentValue: _sliderVal1,
                          onChanged: (val) {
                            setState(() => _sliderVal1 = val);
                            armController.setServoAngle(1, val);
                          },
                        ),
                        _buildServoSlider(
                          label: "Servo 2",
                          servoId: 2,
                          currentValue: _sliderVal2,
                          onChanged: (val) {
                            setState(() => _sliderVal2 = val);
                            armController.setServoAngle(2, val);
                          },
                        ),
                        _buildServoSlider(
                          label: "Servo 3",
                          servoId: 3,
                          currentValue: _sliderVal3,
                          onChanged: (val) {
                            setState(() => _sliderVal3 = val);
                            armController.setServoAngle(3, val);
                          },
                        ),
                        _buildServoSlider(
                          label: "Servo 4",
                          servoId: 4,
                          currentValue: _sliderVal4,
                          onChanged: (val) {
                            setState(() => _sliderVal4 = val);
                            armController.setServoAngle(4, val);
                          },
                        ),
                        _buildServoSlider(
                          label: "Servo 5",
                          servoId: 5,
                          currentValue: _sliderVal5,
                          onChanged: (val) {
                            setState(() => _sliderVal5 = val);
                            armController.setServoAngle(5, val);
                          },
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

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // 請根據您的 LiveKit 服務替換下列 URL 與 token
  final String url = 'wss://test-wfkuoo8g.livekit.cloud'; 
  final String token = ' eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJuYW1lIjoid2ViLXJlY2VpdmVyIiwidmlkZW8iOnsicm9vbUpvaW4iOnRydWUsInJvb20iOiJteS1yb29tIiwiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuU3Vic2NyaWJlIjp0cnVlLCJjYW5QdWJsaXNoRGF0YSI6dHJ1ZX0sInN1YiI6IndlYi1yZWNlaXZlciIsImlzcyI6IkFQSVQ1OFd5enFQN1hQTSIsIm5iZiI6MTc0MzAxMjAwOSwiZXhwIjoxNzQzMDMzNjA5fQ.KefDCiTMC2YZLfbBBItfy-7eh_m7P3bw5ZkpSWtVgN8';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiveKit Receiver Test',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: LiveKitReceiver(url: url, token: token),
    );
  }
}

class LiveKitReceiver extends StatefulWidget {
  final String url;
  final String token;

  const LiveKitReceiver({Key? key, required this.url, required this.token})
      : super(key: key);

  @override
  _LiveKitReceiverState createState() => _LiveKitReceiverState();
}

class _LiveKitReceiverState extends State<LiveKitReceiver> {
  Room? _room;
  RemoteVideoTrack? _videoTrack;

  @override
  void initState() {
    super.initState();
    _connectRoom();
  }

  Future<void> _connectRoom() async {
    try {
      // 建立 Room 並設定基本選項
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      // 可選：呼叫 prepareConnection 可加速連線
      await room.prepareConnection(widget.url, widget.token);
      await room.connect(widget.url, widget.token);
      print('Connected to room: ${room.name}');

      // 加入 listener 當房間狀態改變時更新 UI
      room.addListener(() {
        setState(() {});
      });

      // 嘗試從已連線的遠端參與者中取得視頻軌道
      for (final participant in room.remoteParticipants.values) {
        for (final pub in participant.trackPublications.values) {
          // 直接用型別檢查，如果是 RemoteVideoTrack，就使用它
          if (pub.track != null && pub.track is RemoteVideoTrack) {
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
    return Scaffold(
      appBar: AppBar(
        title: Text('LiveKit Receiver Test'),
      ),
      body: Center(
        child: _videoTrack != null
            ? VideoTrackRenderer(_videoTrack!)
            : Container(
                width: 480,
                height: 360,
                color: Colors.grey,
                child: Center(
                  child: Text(
                    '等待視頻流到來...',
                    style: TextStyle(fontSize: 20, color: Colors.white),
                  ),
                ),
              ),
      ),
    );
  }
}


/*
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/motor_control_page.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arm Controller',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MotorControlPage(),
    );
  }
}
*/
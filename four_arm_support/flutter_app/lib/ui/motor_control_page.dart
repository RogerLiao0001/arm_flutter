// lib/ui/motor_control_page.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode/Decode
import 'dart:math' as math; // For pi constant
import 'dart:typed_data'; // For Uint8List
import 'dart:ui' as ui; // For Canvas painting
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk; // Use prefix
import 'package:mqtt_client/mqtt_client.dart' show MqttConnectionState;
import 'package:http/http.dart' as http; // For fetching token
import 'package:url_launcher/url_launcher.dart';

// Import provider and service definitions
import '../providers/arm_controller_provider.dart';
import '../services/mqtt_service.dart';

// =========================================================================
// --- Centralized Configuration for IK Gamepad Control ---
// =========================================================================
class IKConfig {
  // --- Topics (Dynamic) ---
  static String getIkTopic(int armId) => "servo/arm$armId/ik";
  static String getClawTopic(int armId) => "servo/arm$armId/clm";
  static String getServoTopic(int armId, String label) => "servo/arm$armId/$label";

  // --- Topics (Legacy - for backward compatibility ref) ---
  static const String ikTopic = "servo/arm2/ik";
  static const String clawTopic = "servo/arm2/clm";

  // --- Value Ranges (IK Coordinates) ---
  static const double minX = 50;
  static const double maxX = 400;
  static const double minY = -300;
  static const double maxY = 300;
  static const double minZ = 10;
  static const double maxZ = 350;
  
  // --- Step Values (Amount to change per button press) ---
  static const double stepX = 5.0;
  static const double stepY = 5.0;
  static const double stepZ = 5.0;
  static const int clawStepValue = 20; // For incremental claw control

  // --- Axis Mapping for Gamepad Controls ---
  static const Map<String, String> gamepadAxisMapping = {
    'leftPadVertical': 'x',   // Left D-Pad Up/Down controls IK 'x' axis (Forward/Back)
    'rightPadHorizontal': 'y',// Right D-Pad Left/Right controls IK 'y' axis (Left/Right)
    'rightPadVertical': 'z',  // Right D-Pad Up/Down controls IK 'z' axis (Up/Down)
  };

  // --- Axis Inversion Control ---
  static const bool invertX = true;
  static const bool invertY = false;
  static const bool invertZ = false;

  // --- MODIFIED: 新增旋轉軸向的反向控制 ---
  static const bool invertRX = false; // 設定為 true 來反向 rx (roll)
  static const bool invertRY = false; // 設定為 true 來反向 ry (pitch/yaw)
  static const bool invertRZ = true;  // 設定為 true 來反向 rz (pitch/yaw)
  // --- END MODIFIED ---

  // --- Claw Orientation Values (in Radians) ---
  static const double clawUpRad = math.pi / 2; // 手腕朝前 (1.57)
  static const double clawDownRad = math.pi;   // 手腕朝下 (3.14)

  // --- Reset / Zero State (Rotation values are in RADIANS) ---
  static final Map<String, double> resetState = {
    'x': 150,
    'y': 0,
    'z': 150,
    'rx': 0,
    'ry': math.pi, // 預設朝下 (3.14 radians)
    'rz': 0,
  };

  // --- Claw Value Limits ---
  static const int clawMin = 0;
  static const int clawMax = 180;
}


// =======================================================
// ========== INVERSE KINEMATICS IMPLEMENTATION ==========
//          (REMOVED - Now handled by ESP8266)
// =======================================================


// =======================================================
// =========== YOLO DETECTION DATA MODEL =================
// =======================================================

class YoloDetection {
  final String label;
  final double confidence;
  final List<double> box; // [x, y, width, height] normalized (0-1)

  YoloDetection({
    required this.label,
    required this.confidence,
    required this.box,
  });

  factory YoloDetection.fromJson(Map<String, dynamic> json) {
    return YoloDetection(
      label: json['label'] as String,
      confidence: (json['confidence'] as num).toDouble(),
      box: (json['box'] as List).map((e) => (e as num).toDouble()).toList(),
    );
  }
}

// =======================================================
// =========== YOLO OVERLAY PAINTER ======================
// =======================================================

class YoloOverlayPainter extends CustomPainter {
  final List<YoloDetection> detections;
  final Size videoSize;

  YoloOverlayPainter({
    required this.detections,
    required this.videoSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty || videoSize.width == 0 || videoSize.height == 0) return;

    // 綠色細線，適合小畫面
    final paint = Paint()
      ..color = Colors.green
      ..strokeWidth = 1.5 // 細線
      ..style = PaintingStyle.stroke;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (final detection in detections) {
      // 轉換 normalized coordinates 到實際像素
      final x = detection.box[0] * size.width;
      final y = detection.box[1] * size.height;
      final w = detection.box[2] * size.width;
      final h = detection.box[3] * size.height;

      // 繪製邊界框
      canvas.drawRect(
        Rect.fromLTWH(x, y, w, h),
        paint,
      );

      // 繪製標籤（小字體）
      final label = '${detection.label} ${detection.confidence.toStringAsFixed(2)}';
      textPainter.text = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 11, // 小字體
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.green,
        ),
      );
      textPainter.layout();

      // 標籤位置（避免超出畫面）
      final labelY = y > textPainter.height + 4 ? y - textPainter.height - 2 : y + h;
      textPainter.paint(canvas, Offset(x, labelY));
    }
  }

  @override
  bool shouldRepaint(YoloOverlayPainter oldDelegate) {
    return detections != oldDelegate.detections;
  }
}


// --- LiveKit Receiver Widget ---
class LiveKitReceiverWidget extends StatefulWidget {
  final String url;
  final String token;
  final String targetIdentity; // Added parameter

  const LiveKitReceiverWidget({
    Key? key,
    required this.url,
    required this.token,
    required this.targetIdentity,
  }) : super(key: key);

  @override
  _LiveKitReceiverWidgetState createState() => _LiveKitReceiverWidgetState();
}

class _LiveKitReceiverWidgetState extends State<LiveKitReceiverWidget> {
  lk.Room? _room;
  lk.RemoteVideoTrack? _videoTrack;
  bool _connecting = false;
  String? _connectionError;
  Function? _trackSubscribedDisposer;
  Function? _roomDisposer;
  Function? _dataReceivedDisposer;
  Timer? _clearDetectionTimer;
  
  // Mirror state
  bool _isMirrored = false;

  // YOLO detection data (Kept for compatibility but UI hidden/removed as requested)
  List<YoloDetection> _yoloDetections = [];
  DateTime? _lastDetectionTime;
  static const Duration _detectionTimeout = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    if (widget.token.isNotEmpty) {
       WidgetsBinding.instance.addPostFrameCallback((_) => _connectRoom());
    }
    // 啟動定期檢查清除過期偵測的 Timer
    _clearDetectionTimer = Timer.periodic(const Duration(milliseconds: 500), _checkClearDetections);
  }

  @override
  void didUpdateWidget(covariant LiveKitReceiverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url || widget.token != oldWidget.token || widget.targetIdentity != oldWidget.targetIdentity) {
       _disconnectRoom().then((_) {
         if (widget.token.isNotEmpty && mounted) {
           _connectRoom();
         }
       });
    }
  }

  @override
  void dispose() {
    _clearDetectionTimer?.cancel();
    _disconnectRoom();
    super.dispose();
  }

  // 定期檢查並清除過期的偵測結果
  void _checkClearDetections(Timer timer) {
    if (!mounted) return;

    final lastTime = _lastDetectionTime;
    if (lastTime != null && _yoloDetections.isNotEmpty) {
      final elapsed = DateTime.now().difference(lastTime);
      if (elapsed > _detectionTimeout) {
        if (mounted) {
          setState(() {
            _yoloDetections = [];
          });
        }
      }
    }
  }

  Future<void> _disconnectRoom() async {
     _roomDisposer?.call();
     _trackSubscribedDisposer?.call();
     _dataReceivedDisposer?.call();
     if (_room != null) {
       await _room?.disconnect();
     }
     _room = null;
     if (mounted) {
         setState(() {
           _videoTrack = null;
           _yoloDetections = [];
         });
     }
  }

  Future<void> _connectRoom() async {
     if (_connecting || (_room?.connectionState == lk.ConnectionState.connected || _room?.connectionState == lk.ConnectionState.connecting)) return;
     if (widget.token.isEmpty) { setState(() { _connectionError = "Token is missing."; }); return; }

     setState(() { _connecting = true; _videoTrack = null; _connectionError = null; });

     try {
       await _disconnectRoom();
       final room = lk.Room();
       _room = room;

       // 監聽房間事件
       _roomDisposer = room.events.listen((event) {
         if (mounted) setState(() {});
         if (event is lk.RoomDisconnectedEvent) {
           if (mounted) setState(() {
             _videoTrack = null;
             _yoloDetections = [];
           });
         }
       });

       // 監聽影像軌道訂閱 (Filtered by Identity)
       _trackSubscribedDisposer = room.events.on<lk.TrackSubscribedEvent>((event) {
         print("[LiveKit] TrackSubscribedEvent: kind=${event.track.kind}, identity=${event.participant.identity}");
         if (event.track is lk.RemoteVideoTrack && mounted) {
           // Only subscribe if identity matches
           print("[LiveKit] Checking identity match: got '${event.participant.identity}', expected '${widget.targetIdentity}'");
           if (event.participant.identity == widget.targetIdentity) {
              print("[LiveKit] Identity MATCHED! Setting video track.");
              setState(() => _videoTrack = event.track as lk.RemoteVideoTrack);
           } else {
              print("[LiveKit] Identity mismatch. Ignoring track.");
           }
         }
       });

       // *** 新增：監聽 Data Channel 接收 YOLO 資料 ***
       _dataReceivedDisposer = room.events.on<lk.DataReceivedEvent>((event) {
         if (!mounted) return;

         final participant = event.participant;
         if (participant != null && participant.identity == 'yolo-bot') {
           try {
             // 解碼 Data Channel 資料
             final jsonString = utf8.decode(event.data);
             final data = jsonDecode(jsonString);

             // 只處理偵測結果（陣列），忽略模型列表（物件）
             if (data is List) {
               final detections = data
                   .map((item) => YoloDetection.fromJson(item as Map<String, dynamic>))
                   .toList();

               if (mounted) {
                 setState(() {
                   _yoloDetections = detections;
                   _lastDetectionTime = DateTime.now();
                 });
               }
             }
           } catch (e) {
             if (kDebugMode) {
               print('Failed to parse YOLO data: $e');
             }
           }
         }
       });

       print("[LiveKit] Connecting to room with URL: ${widget.url}");
       // Disable adaptiveStream and dynacast for stability debugging
       await room.connect( widget.url, widget.token, roomOptions: const lk.RoomOptions( adaptiveStream: false, dynacast: false,),);
       print("[LiveKit] Room connected!");
       
       if (mounted && _videoTrack == null && room.connectionState == lk.ConnectionState.connected) { 
           print("[LiveKit] Checking existing tracks...");
           _checkForExistingTracks(room); 
       }
       if (mounted) setState(() => _connecting = false);
     } catch (e) {
       print("[LiveKit] Connection ERROR: $e");
       if (mounted) { setState(() { _connecting = false; _connectionError = 'Connection failed: $e'; }); }
       await _disconnectRoom();
     }
  }

  void _checkForExistingTracks(lk.Room room) {
     for (final participant in room.remoteParticipants.values) {
       print("[LiveKit] Existing participant: ${participant.identity}");
       if (participant.identity != widget.targetIdentity) {
           print("[LiveKit] Skipping participant ${participant.identity} (not target)");
           continue; 
       }
       for (final pub in participant.videoTrackPublications) {
         if (pub.track != null && pub.track is lk.RemoteVideoTrack) {
           print("[LiveKit] Found existing video track for target!");
           if (mounted) { setState(() => _videoTrack = pub.track as lk.RemoteVideoTrack); return; }
         }
       }
     }
   }

   @override
  Widget build(BuildContext context) {
    Widget content;
    if (_connecting) { content = const Center(child: CircularProgressIndicator(color: Colors.white)); }
    else if (_connectionError != null) { content = Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [ const Icon(Icons.error_outline, color: Colors.red, size: 40), const SizedBox(height: 10), Text('LiveKit Error:', style: TextStyle(color: Colors.red[200], fontWeight: FontWeight.bold)), const SizedBox(height: 5), Text(_connectionError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)), const SizedBox(height: 20), ElevatedButton.icon( icon: const Icon(Icons.refresh), label: const Text("Retry Connection"), onPressed: widget.token.isNotEmpty ? _connectRoom : null, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[700]),)],),),); }
    else if (_videoTrack != null) {
      // *** 使用 Stack 疊加 UI ***
      content = Stack(
        children: [
          // 底層：影像播放器 (支援鏡像)
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scale(_isMirrored ? -1.0 : 1.0, 1.0),
            child: lk.VideoTrackRenderer(_videoTrack!),
          ),

          // 上層：鏡像切換按鈕 (右上角)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white54,
                  width: 1.5,
                ),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 24,
                icon: Icon(
                  Icons.flip,
                  color: _isMirrored ? Theme.of(context).primaryColor : Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _isMirrored = !_isMirrored;
                  });
                },
                tooltip: 'Mirror Video',
              ),
            ),
          ),
        ],
      );
    }
    else if (_room?.connectionState == lk.ConnectionState.connected) { content = const Center(child: Text('Connected, waiting for video stream...', style: TextStyle(color: Colors.grey))); }
    else { content = Center( child: Column( mainAxisAlignment: MainAxisAlignment.center, children: [ const Text('Stream unavailable', style: TextStyle(color: Colors.grey)), const SizedBox(height: 15), if (_room?.connectionState != lk.ConnectionState.connecting && widget.token.isNotEmpty) ElevatedButton.icon( icon: const Icon(Icons.refresh), label: const Text("Connect Stream"), onPressed: _connectRoom, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[700]),), if (widget.token.isEmpty) const Text('Missing connection token.', style: TextStyle(color: Colors.orange)),],)); }
    return Container( color: Colors.black, width: double.infinity, height: double.infinity, child: content,);
  }
}

// === FeedbackControlButton Widget ===
class FeedbackControlButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback onUpdate;
  final double padding;

  const FeedbackControlButton({
    Key? key,
    required this.icon,
    required this.onUpdate,
    this.padding = 8.0,
  }) : super(key: key);

  @override
  _FeedbackControlButtonState createState() => _FeedbackControlButtonState();
}

class _FeedbackControlButtonState extends State<FeedbackControlButton> {
  bool _isPressed = false;
  Timer? _motorUpdateTimer;

  @override
  void dispose() {
    _motorUpdateTimer?.cancel();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    setState(() {
      _isPressed = true;
    });
    _motorUpdateTimer?.cancel();
    widget.onUpdate(); // Fire once immediately
    _motorUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      widget.onUpdate();
    });
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() {
      _isPressed = false;
    });
    _motorUpdateTimer?.cancel();
  }

  void _handleTapCancel() {
    setState(() {
      _isPressed = false;
    });
    _motorUpdateTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double elevation = _isPressed ? 1.0 : 4.0;
    final Color color = _isPressed ? theme.primaryColor.withOpacity(0.1) : theme.cardColor;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: EdgeInsets.all(widget.padding),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: _isPressed ? Colors.grey.shade400 : Colors.grey.shade500,
              blurRadius: elevation * 1.5,
              spreadRadius: 1,
              offset: Offset(0, elevation),
            ),
          ],
        ),
        child: widget.icon,
      ),
    );
  }
}


// --- Main Control Page ---
class MotorControlPage extends ConsumerStatefulWidget {
  const MotorControlPage({Key? key}) : super(key: key);

  @override
  ConsumerState<MotorControlPage> createState() => _MotorControlPageState();
}

class _MotorControlPageState extends ConsumerState<MotorControlPage> {
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  Key _receiverKey = UniqueKey();
  String? _fetchedLivekitToken;
  bool _isFetchingToken = false;
  String? _tokenError;
  int _selectedControlTabIndex = 0;
  final List<bool> _isSelected = [true, false];
  
  // --- Multi-Arm Support ---
  int _selectedArmId = 1; // Default to Arm 1
  final List<int> _availableArms = [1, 2, 3, 4];

  late Map<String, double> _ikState;
  late int _clawValue;
  
  double _arm2SliderValA = 90, _arm2SliderValB = 90, _arm2SliderValC = 90;
  double _arm2SliderValD = 90, _arm2SliderValE = 90, _arm2SliderValF = 90;

  final Map<String, DateTime> _lastSendTime = {};
  final Duration _throttleDuration = const Duration(milliseconds: 50);

  void _publishThrottled(MqttService mqttService, String controlId, String topic, String payload) {
    final now = DateTime.now();
    if (_lastSendTime[controlId] == null || now.difference(_lastSendTime[controlId]!) > _throttleDuration) {
      // Final safety check: if the generated payload is somehow STILL too long, truncate it.
      if (payload.length > 32) {
        print("!!! CRITICAL WARNING: Payload '${payload}' (${payload.length} bytes) exceeded 32 and was TRUNCATED.");
        payload = payload.substring(0, 32);
      }
      mqttService.publish(topic, payload);
      _lastSendTime[controlId] = now;
    }
  }

   @override
   void initState() {
     super.initState();
     _ikState = Map<String, double>.from(IKConfig.resetState);
     _clawValue = IKConfig.clawMax;
     
     WidgetsBinding.instance.addPostFrameCallback((_) {
         final mqttService = ref.read(mqttServiceProvider);
         if (mqttService.connectionState != MqttConnectionState.connected && mqttService.connectionState != MqttConnectionState.connecting) {
            mqttService.connect();
         }
         mqttService.setOnMessageReceivedCallback(_handleMqttMessage);
         _publishIKState(mqttService);
     });
     _fetchAndSetLiveKitToken();
   }

  @override
  void dispose() {
    super.dispose();
  }

   void _handleMqttMessage(String topic, String payload) {
       print("MQTT Message Received in UI: $topic -> $payload");
   }

   Future<void> _fetchAndSetLiveKitToken() async {
     if (_isFetchingToken) return;
     setState(() { _isFetchingToken = true; _tokenError = null; _fetchedLivekitToken = null; });
     
     // Use relative path for Web to avoid CORS and domain issues
     final String uniqueIdentity = 'flutter-viewer-${DateTime.now().millisecondsSinceEpoch}';
     final String tokenApiUrl = kIsWeb 
         ? '/get-livekit-token?identity=$uniqueIdentity&room=my-room'
         : 'https://robotic-arm.site/get-livekit-token?identity=$uniqueIdentity&room=my-room';
         
     print("[LiveKit] Fetching token from: $tokenApiUrl"); // Debug Log
     try {
       final response = await http.get(Uri.parse(tokenApiUrl)).timeout(const Duration(seconds: 15));
       print("[LiveKit] Token response status: ${response.statusCode}"); // Debug Log
       if (!mounted) return;
       if (response.statusCode == 200) {
         final jsonResponse = jsonDecode(response.body);
         final token = jsonResponse['token'];
         if (token != null && token is String && token.isNotEmpty) {
           setState(() { _fetchedLivekitToken = token; _isFetchingToken = false; _receiverKey = UniqueKey(); });
         } else { throw Exception('Token invalid or not found in response'); }
       } else { throw Exception('Failed to load token (${response.statusCode}): ${response.body}'); }
     } catch (e) {
       if (mounted) { setState(() { _tokenError = 'Token fetch failed.'; _isFetchingToken = false; _fetchedLivekitToken = null; _receiverKey = UniqueKey(); }); }
     }
   }

   Future<void> _editStreamingSettings() async {
    TextEditingController urlController = TextEditingController(text: livekitUrl);
    await showDialog(context: context, builder: (context) => AlertDialog(title: const Text("Modify Streaming URL"), content: TextField( controller: urlController, decoration: const InputDecoration(labelText: "LiveKit URL"),), actions: [ TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel"),), TextButton(onPressed: () { if (mounted) { final newUrl = urlController.text.trim(); if (newUrl.isNotEmpty && newUrl != livekitUrl) { setState(() { livekitUrl = newUrl; _receiverKey = UniqueKey(); }); } } Navigator.of(context).pop(); }, child: const Text("Save URL"),), ],),);
   }

  // =========================================================================
  // --- *** CORE FIX: Adaptive precision publishing logic *** ---
  // =========================================================================
  void _publishIKState(MqttService mqttService) {
    final int x = _ikState['x']!.round();
    final int y = _ikState['y']!.round();
    final int z = _ikState['z']!.round();
    
    // --- MODIFIED: 應用旋轉軸向反向邏輯 ---
    // 1. 從狀態中讀取原始旋轉值
    final double rxRawRad = _ikState['rx']!;
    final double ryRawRad = _ikState['ry']!;
    final double rzRawRad = _ikState['rz']!;

    // 2. 根據 IKConfig 的設定決定最終值
    final double rxRad = IKConfig.invertRX ? -rxRawRad : rxRawRad;
    final double ryRad = IKConfig.invertRY ? -ryRawRad : ryRawRad;
    final double rzRad = IKConfig.invertRZ ? -rzRawRad : rzRawRad;
    // --- END MODIFIED ---
    
    String payload;
    int precision = 2; // Start with the desired precision

    // Loop to reduce precision if the payload is too long
    while (precision >= 0) {
      // Format the payload with the current precision level
      if (precision > 0) {
        // 使用經過反向處理後的值 (rxRad, ryRad, rzRad)
        payload = "IK $x $y $z ${rxRad.toStringAsFixed(precision)} ${ryRad.toStringAsFixed(precision)} ${rzRad.toStringAsFixed(precision)}";
      } else { // For precision 0, use integers to avoid ".0"
        payload = "IK $x $y $z ${rxRad.round()} ${ryRad.round()} ${rzRad.round()}";
      }
      
      // If the payload is within the 32-byte limit, break the loop and send it
      if (payload.length <= 32) {
        print("Publishing IK (P:$precision): $payload (${payload.length} bytes) to Arm $_selectedArmId");
        _publishThrottled(mqttService, 'ik_gamepad', IKConfig.getIkTopic(_selectedArmId), payload);
        return; // Exit the function
      }
      
      // If it's too long, reduce precision and try again
      precision--;
    }
    
    // If even with 0 precision it's too long, it will be caught and truncated by _publishThrottled.
    // We send the last generated (precision 0) payload as a fallback.
    payload = "IK $x $y $z ${rxRad.round()} ${ryRad.round()} ${rzRad.round()}";
    print("Publishing IK (P:0, as fallback): $payload (${payload.length} bytes) to Arm $_selectedArmId");
    _publishThrottled(mqttService, 'ik_gamepad', IKConfig.getIkTopic(_selectedArmId), payload);
  }

  /// Handles arm POSITION changes (x, y, z)
  void _incrementIKValue(MqttService mqttService, { required String axis, required double step, }) {
    double effectiveStep = step;
    if ((axis == 'x' && IKConfig.invertX) ||
        (axis == 'y' && IKConfig.invertY) ||
        (axis == 'z' && IKConfig.invertZ)) {
      effectiveStep = -step;
    }
    setState(() {
      double currentValue = _ikState[axis]!;
      double newValue = currentValue + effectiveStep;
      if (axis == 'x') { newValue = newValue.clamp(IKConfig.minX, IKConfig.maxX); } 
      else if (axis == 'y') { newValue = newValue.clamp(IKConfig.minY, IKConfig.maxY); } 
      else if (axis == 'z') { newValue = newValue.clamp(IKConfig.minZ, IKConfig.maxZ); }
      _ikState[axis] = newValue;
    });
    _publishIKState(mqttService);
  }
  
  /// Handles arm ORIENTATION changes (ry)
  void _setIKRotation(MqttService mqttService, { required double newRy }) {
      setState(() { _ikState['ry'] = newRy; });
      _publishIKState(mqttService);
  }

  void _incrementClaw(MqttService mqttService, { required bool isPositive }) {
    setState(() {
      int change = isPositive ? IKConfig.clawStepValue : -IKConfig.clawStepValue;
      _clawValue = (_clawValue + change).clamp(IKConfig.clawMin, IKConfig.clawMax);
    });
    final payload = 'clm $_clawValue';
    _publishThrottled(mqttService, 'claw_gamepad', IKConfig.getClawTopic(_selectedArmId), payload);
    print("Publishing: $payload to Arm $_selectedArmId");
  }

  void _resetIKStateAndPublish(MqttService mqttService) {
    setState(() {
      _ikState = Map<String, double>.from(IKConfig.resetState);
      _clawValue = IKConfig.clawMax;
    });
    _publishIKState(mqttService);
    mqttService.publish(IKConfig.getClawTopic(_selectedArmId), 'clm $_clawValue');
    print("IK state and claw have been reset to default values for Arm $_selectedArmId.");
  }
  
  Widget _buildVerticalSlider({
    required String label, required String controlId, required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Padding( padding: const EdgeInsets.symmetric(horizontal: 4.0), child: Column( mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [ Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center,), const SizedBox(height: 8), SizedBox( height: 180, child: RotatedBox( quarterTurns: -1, child: Slider( value: value, min: 0, max: 180, divisions: 180, label: "${value.toInt()}°", onChanged: onChanged,),),), const SizedBox(height: 4), Text("${value.toInt()}°", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),), ],),);
  }

  Widget _buildGamepadControls(MqttService mqttService) {
    final screenWidth = MediaQuery.of(context).size.width;
    final double arrowIconSize = screenWidth < 360 ? 20.0 : 28.0;
    final double addRemoveIconSize = screenWidth < 360 ? 18.0 : 24.0;
    final double innerPadding = screenWidth < 360 ? 8.0 : 12.0;
    final double spacerWidth = math.min(44.0, math.max(20.0, screenWidth * 0.07));
    final double horizontalPad = screenWidth < 360 ? 6.0 : 12.0;
    final double smallLabelSize = screenWidth < 360 ? 10.0 : 11.0;
    final double clawLabelSize = screenWidth < 360 ? 11.0 : 12.0;

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPad, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.keyboard_double_arrow_up, size: arrowIconSize, color: Theme.of(context).primaryColor),
                    onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['leftPadVertical']!, step: IKConfig.stepX),
                  ),
                  SizedBox(height: screenWidth < 360 ? 3 : 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                       FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.align_horizontal_right, size: addRemoveIconSize, color: Theme.of(context).primaryColor),
                        onUpdate: () => _setIKRotation(mqttService, newRy: IKConfig.clawUpRad),
                      ),
                      SizedBox(width: spacerWidth),
                      FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.align_vertical_top, size: addRemoveIconSize, color: Theme.of(context).primaryColor),
                        onUpdate: () => _setIKRotation(mqttService, newRy: IKConfig.clawDownRad),
                      ),
                    ],
                  ),
                  SizedBox(height: screenWidth < 360 ? 3 : 4),
                  FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.keyboard_double_arrow_down, size: arrowIconSize, color: Theme.of(context).primaryColor),
                    onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['leftPadVertical']!, step: -IKConfig.stepX),
                  ),
                  SizedBox(height: screenWidth < 360 ? 6 : 8),
                  Text("X (Fwd/Back)", style: TextStyle(fontSize: smallLabelSize, color: Colors.black54, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Claw", style: TextStyle(fontWeight: FontWeight.bold, fontSize: clawLabelSize)),
                  SizedBox(height: screenWidth < 360 ? 6 : 8),
                   FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.add, size: addRemoveIconSize, color: Theme.of(context).primaryColor),
                    onUpdate: () => _incrementClaw(mqttService, isPositive: true),
                  ),
                  SizedBox(height: screenWidth < 360 ? 8 : 12),
                   FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.remove, size: addRemoveIconSize, color: Theme.of(context).primaryColor),
                    onUpdate: () => _incrementClaw(mqttService, isPositive: false),
                  ),
                ],
              ),
            ),

            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.arrow_upward, size: arrowIconSize, color: Theme.of(context).primaryColor),
                    onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadVertical']!, step: IKConfig.stepZ),
                  ),
                  SizedBox(height: screenWidth < 360 ? 3 : 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.arrow_back, size: arrowIconSize, color: Theme.of(context).primaryColor),
                        onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadHorizontal']!, step: -IKConfig.stepY),
                      ),
                      SizedBox(width: spacerWidth),
                      FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.arrow_forward, size: arrowIconSize, color: Theme.of(context).primaryColor),
                        onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadHorizontal']!, step: IKConfig.stepY),
                      ),
                    ],
                  ),
                  SizedBox(height: screenWidth < 360 ? 3 : 4),
                  FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.arrow_downward, size: arrowIconSize, color: Theme.of(context).primaryColor),
                    onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadVertical']!, step: -IKConfig.stepZ),
                  ),
                  SizedBox(height: screenWidth < 360 ? 6 : 8),
                  Text("Y/Z Plane (Side/Up)", style: TextStyle(fontSize: smallLabelSize, color: Colors.black54, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArm2Controls(MqttService mqttService) {
     final Map<int, String> arm2Labels = { 1: 'a', 2: 'b', 3: 'c', 4: 'd', 5: 'e', 6: 'f' };
     final Map<int, String> arm2MotorTypes = { 1: 'Servo', 2: 'Servo', 3: 'Servo', 4: 'Stepper', 5: 'Stepper', 6: 'Stepper' };

     return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
        child: Column(
          children: [
            Row(
              children: [
                const Text("Direct Control (Sliders)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() => _clawValue = IKConfig.clawMax);
                    mqttService.publish(IKConfig.getClawTopic(_selectedArmId), 'clm ${IKConfig.clawMax}');
                  },
                  child: const Text("Open"),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _clawValue = IKConfig.clawMin);
                    mqttService.publish(IKConfig.getClawTopic(_selectedArmId), 'clm ${IKConfig.clawMin}');
                  },
                  child: const Text("Close"),
                ),
              ],
            ),
            const Divider(height: 15, thickness: 1),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: List.generate(6, (index) {
                      int motorIndex = index + 1;
                      String label = arm2Labels[motorIndex]!;
                      String motorTypeLabel = "${arm2MotorTypes[motorIndex]} ${label.toUpperCase()}";
                      String controlId = 'arm${_selectedArmId}_slider_$label';
                      double currentValue;
                      switch (motorIndex) {
                        case 1: currentValue = _arm2SliderValA; break; case 2: currentValue = _arm2SliderValB; break;
                        case 3: currentValue = _arm2SliderValC; break; case 4: currentValue = _arm2SliderValD; break;
                        case 5: currentValue = _arm2SliderValE; break; case 6: currentValue = _arm2SliderValF; break;
                        default: currentValue = 90;
                      }

                      return _buildVerticalSlider(
                        label: motorTypeLabel, controlId: controlId, value: currentValue,
                        onChanged: (v) {
                          setState(() {
                            switch (motorIndex) {
                              case 1: _arm2SliderValA = v; break; case 2: _arm2SliderValB = v; break;
                              case 3: _arm2SliderValC = v; break; case 4: _arm2SliderValD = v; break;
                              case 5: _arm2SliderValE = v; break; case 6: _arm2SliderValF = v; break;
                            }
                          });
                          // Use dynamic topic
                          final topic = IKConfig.getServoTopic(_selectedArmId, label);
                          final payload = jsonEncode({"angle": v.toInt()});
                          _publishThrottled(mqttService, controlId, topic, payload);
                        },
                      );
                    }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mqttService = ref.watch(mqttServiceProvider);
    final connectionState = mqttService.connectionState;
    String connectionStatus; Color statusColor;
    switch (connectionState) {
      case MqttConnectionState.connected: connectionStatus = "Connected"; statusColor = Colors.green.shade600; break;
      case MqttConnectionState.connecting: connectionStatus = "Connecting..."; statusColor = Colors.orange.shade600; break;
      case MqttConnectionState.disconnected: connectionStatus = "Disconnected"; statusColor = Colors.red.shade600; break;
      case MqttConnectionState.disconnecting: connectionStatus = "Disconnecting..."; statusColor = Colors.orange.shade400; break;
      case MqttConnectionState.faulted: connectionStatus = "Faulted"; statusColor = Colors.red.shade800; break;
      default: connectionStatus = "Unknown"; statusColor = Colors.grey.shade500;
    }

     Widget liveKitContentArea;
     if (_isFetchingToken) { liveKitContentArea = const Center(child: CircularProgressIndicator()); }
     else if (_tokenError != null) { liveKitContentArea = Center( child: Padding( padding: const EdgeInsets.all(16.0), child: Column( mainAxisSize: MainAxisSize.min, children: [ Icon(Icons.cloud_off, color: Colors.red[300], size: 30), const SizedBox(height: 8), Text(_tokenError!, style: TextStyle(color: Colors.red[300])), const SizedBox(height: 10), ElevatedButton.icon( icon: const Icon(Icons.refresh), label: const Text("Retry Fetch"), onPressed: _fetchAndSetLiveKitToken, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey)) ],),),); }
     else if (_fetchedLivekitToken == null) { liveKitContentArea = Center( child: Column( mainAxisSize: MainAxisSize.min, children: [ Icon(Icons.vpn_key_off_outlined, color: Colors.orange[300], size: 30), const SizedBox(height: 8), Text("LiveKit token needed.", style: TextStyle(color: Colors.orange[300])), const SizedBox(height: 10), ElevatedButton.icon( icon: const Icon(Icons.vpn_key), label: const Text("Get Token"), onPressed: _fetchAndSetLiveKitToken, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey)) ],),); }
     else { 
       liveKitContentArea = LiveKitReceiverWidget( 
         key: _receiverKey, 
         url: livekitUrl, 
         token: _fetchedLivekitToken!,
         targetIdentity: 'webcam-publisher-arm$_selectedArmId', // Filter by selected arm
       ); 
     }

    return Scaffold(
      appBar: AppBar(
         title: const Text("Robotic Arm"),
         actions: [
          // --- Arm Selection Dropdown ---
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedArmId,
              dropdownColor: Colors.white, // Fixed: White background
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold), // Fixed: Black text
              icon: const Icon(Icons.arrow_drop_down, color: Colors.black54), // Darker icon
              items: _availableArms.map((int id) {
                return DropdownMenuItem<int>(
                  value: id,
                  child: Text(' Arm $id ', style: const TextStyle(color: Colors.black)),
                );
              }).toList(),
              selectedItemBuilder: (BuildContext context) {
                return _availableArms.map<Widget>((int id) {
                  return Center(child: Text('Arm $id', style: const TextStyle(color: Colors.black))); // AppBar text color
                }).toList();
              },
              onChanged: (int? newValue) {
                if (newValue != null) {
                  setState(() {
                    _selectedArmId = newValue;
                    // Force LiveKit widget to rebuild/update filter when arm changes
                    // The 'targetIdentity' prop update will handle this in didUpdateWidget
                  });
                }
              },
            ),
          ),
         IconButton(
           icon: const Icon(Icons.videocam),
           tooltip: "Open Camera Page",
           onPressed: () async {
             final publisherUrl = Uri.parse('https://robotic-arm.site/camera.html');
             if (await canLaunchUrl(publisherUrl)) {
               await launchUrl(publisherUrl, mode: LaunchMode.externalApplication);
             } else {
               if(mounted) {
                 ScaffoldMessenger.of(context).showSnackBar(
                   SnackBar(content: Text('Could not launch ${publisherUrl.toString()}')),
                 );
               }
             }
           },
         ),
         IconButton(icon: const Icon(Icons.refresh), tooltip: "Refresh LiveKit Token", onPressed: _fetchAndSetLiveKitToken,),
         IconButton( icon: const Icon(Icons.settings_input_component), tooltip: "Edit LiveKit URL", onPressed: _editStreamingSettings,),
       ],
      ),
      body: Column( children: [
          Expanded( flex: 4, child: Container( width: double.infinity, color: Colors.black, child: liveKitContentArea,),),
          Container( height: 55, color: Theme.of(context).cardTheme.color ?? Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16.0), child: Row( mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ Row(children: [ Icon(Icons.rss_feed, size: 20, color: statusColor), const SizedBox(width: 8), Container( width: 10, height: 10, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),), const SizedBox(width: 8), Text(connectionStatus, style: TextStyle(fontSize: 15, color: statusColor, fontWeight: FontWeight.w500)),],), IconButton( icon: const Icon(Icons.sync_problem_outlined), tooltip: "Reconnect MQTT", color: Theme.of(context).primaryColor, iconSize: 24, onPressed: (connectionState == MqttConnectionState.connecting || connectionState == MqttConnectionState.disconnecting) ? null : () { mqttService.disconnect(); Future.delayed(const Duration(milliseconds: 300), () { if (mounted) { mqttService.connect(); } }); },), ],),),
          Expanded( flex: 6, child: Container( color: Colors.grey[200], padding: const EdgeInsets.fromLTRB(8.0, 0, 8.0, 8.0), child: Column( crossAxisAlignment: CrossAxisAlignment.stretch, children: [
             Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ToggleButtons(
                    isSelected: _isSelected,
                    onPressed: (int index) {
                      if (_isSelected[index]) return;
                      setState(() { _selectedControlTabIndex = index; for (int i = 0; i < _isSelected.length; i++) { _isSelected[i] = (i == index); } });
                    },
                    color: Colors.grey.shade600,
                    selectedColor: Theme.of(context).primaryColor,
                    fillColor: Theme.of(context).primaryColor.withOpacity(0.12),
                    borderColor: Colors.grey.shade400,
                    selectedBorderColor: Theme.of(context).primaryColor,
                    borderRadius: BorderRadius.circular(8.0),
                    constraints: const BoxConstraints(minHeight: 38.0),
                    children: const <Widget>[
                      Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Gamepad')),
                      Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Sliders')),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: "Reset All Motors",
                    onPressed: () => _resetIKStateAndPublish(mqttService),
                    color: Colors.grey[700],
                  ),
                ],
              ),
            ),
             Expanded( child: AnimatedSwitcher( duration: const Duration(milliseconds: 200), transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child), child: _selectedControlTabIndex == 0 ? Container(key: const ValueKey('gamepad_controls'), child: _buildGamepadControls(mqttService)) : Container(key: const ValueKey('slider_controls'), child: _buildArm2Controls(mqttService)),),),],),),),
        ],
      ),
    );
  }
}
// lib/ui/motor_control_page.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode/Decode
import 'dart:math' as math; // For pi constant
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk; // Use prefix
import 'package:mqtt_client/mqtt_client.dart' show MqttConnectionState;
import 'package:http/http.dart' as http; // For fetching token
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_math/vector_math_64.dart' as vm; // 用於運動學計算

// Import provider and service definitions
import '../providers/arm_controller_provider.dart';
import '../services/mqtt_service.dart';

// =========================================================================
// --- Centralized Configuration for IK Gamepad Control ---
// =========================================================================
class IKConfig {
  // --- Topics ---
  // static const String ikTopic = "servo/arm2/ik"; // 舊的IK主題，不再使用
  static const String jmTopic = "servo/arm2/servo"; // 傳送馬達角度的新主題
  static const String clawTopic = "servo/arm2/clm";

  // --- Value Ranges (IK Coordinates) ---
  static const double minX = 50;
  static const double maxX = 250;
  static const double minY = -400;
  static const double maxY = 400;
  static const double minZ = 100;
  static const double maxZ = 350;
  
  // --- Step Values (Amount to change per button press) ---
  static const double stepX = 5.0;
  static const double stepY = 5.0;
  static const double stepZ = 5.0;
  static const int clawStepValue = 10; // For incremental claw control

  // --- Axis Mapping for Gamepad Controls ---
  // Maps UI control directions to the logical IK axes ('x', 'y', 'z')
  static const Map<String, String> gamepadAxisMapping = {
    'leftPadVertical': 'x',   // Left D-Pad Up/Down controls IK 'x' axis (Forward/Back)
    'rightPadHorizontal': 'y',// Right D-Pad Left/Right controls IK 'y' axis (Left/Right)
    'rightPadVertical': 'z',  // Right D-Pad Up/Down controls IK 'z' axis (Up/Down)
  };

  // --- Axis Inversion Control (新增) ---
  // 將任一軸設為 true 可反轉其控制方向
  static const bool invertX = false;
  static const bool invertY = false;
  static const bool invertZ = false;

  // --- Claw Orientation Values (in Radians) ---
  static const double clawUpRad = 1.57; // 手腕朝前
  static const double clawDownRad = 3.14; // 手腕朝下

  // --- Reset / Zero State ---
  static final Map<String, double> resetState = {
    'x': 150,
    'y': 0,
    'z': 150,
    'rx': 0,
    'ry': 3.14, // 預設朝下
    'rz': 0,
  };

  // --- Claw Value Limits ---
  static const int clawMin = 0;
  static const int clawMax = 100;
}


// =======================================================
// ========== INVERSE KINEMATICS IMPLEMENTATION ==========
// =======================================================

// DH參數表 (Denavit-Hartenberg Parameters)
final Map<String, List<double>> _dhParams = {
  'alpha': [-math.pi / 2, 0, math.pi / 2, -math.pi / 2, math.pi / 2, 0],
  'a': [0, 252.625, 0, 0, 0, 0],
  'd': [136.1, 0, 0, 0, 214.6, 119.47],
};

/// 根據Standard DH參數計算單一變換矩陣 (4x4)
vm.Matrix4 _dhTransformMatrix(double theta, double alpha, double a, double d) {
  return vm.Matrix4(
    math.cos(theta), -math.sin(theta) * math.cos(alpha),  math.sin(theta) * math.sin(alpha), a * math.cos(theta),
    math.sin(theta),  math.cos(theta) * math.cos(alpha), -math.cos(theta) * math.sin(alpha), a * math.sin(theta),
    0,                math.sin(alpha),                    math.cos(alpha),                    d,
    0,                0,                                  0,                                  1,
  )..transpose(); // vector_math is column-major, so we transpose
}

/// 將 ZYX Euler 角度 (弧度) 轉換為旋轉矩陣 (3x3)
vm.Matrix3 _eulerToRotMatrix(double yaw, double pitch, double roll) {
  final Rz = vm.Matrix3.rotationZ(yaw);
  final Ry = vm.Matrix3.rotationY(pitch);
  final Rx = vm.Matrix3.rotationX(roll);
  return Rz * Ry * Rx;
}

/// 逆向運動學主函式 (用於位置移動)
List<double>? calculateInverseKinematics(double x, double y, double z, double yaw, double pitch, double roll) {
  try {
    final d0 = _dhParams['d']![0];
    final a1 = _dhParams['a']![1];
    final d4 = _dhParams['d']![4];
    final d5 = _dhParams['d']![5];
    
    final R_0_6 = _eulerToRotMatrix(yaw, pitch, roll);
    final p_e = vm.Vector3(x, y, z);
    
    final p_wc = p_e - R_0_6.getColumn(2) * d5;
    final x_wc = p_wc.x;
    final y_wc = p_wc.y;
    final z_wc = p_wc.z;
    
    final j0 = math.atan2(y_wc, x_wc);
    
    final r_sq = x_wc * x_wc + y_wc * y_wc;
    final s = z_wc - d0;
    final D_sq = r_sq + s * s;
    
    final cosValJ2 = (D_sq - a1 * a1 - d4 * d4) / (2 * a1 * d4);
    if (cosValJ2.abs() > 1.0001) return null;
    
    final j2 = math.acos(cosValJ2.clamp(-1.0, 1.0)); // "手肘向上" 解

    final s_j2 = math.sin(j2);
    final c_j2 = math.cos(j2);
    final k1 = a1 + d4 * c_j2;
    final k2 = d4 * s_j2;
    
    final j1 = math.atan2(s, math.sqrt(r_sq)) - math.atan2(k2, k1);

    final T_0_1 = _dhTransformMatrix(j0, _dhParams['alpha']![0], _dhParams['a']![0], _dhParams['d']![0]);
    final T_1_2 = _dhTransformMatrix(j1, _dhParams['alpha']![1], _dhParams['a']![1], _dhParams['d']![1]);
    final T_2_3 = _dhTransformMatrix(j2, _dhParams['alpha']![2], _dhParams['a']![2], _dhParams['d']![2]);
    
    final T_0_3 = T_0_1 * T_1_2 * T_2_3;
    final R_0_3 = T_0_3.getRotation();
    
    final R_3_6 = R_0_3.transposed() * R_0_6;
    
    final r13 = R_3_6.entry(0, 2);
    final r23 = R_3_6.entry(1, 2);
    final r31 = R_3_6.entry(2, 0);
    final r32 = R_3_6.entry(2, 1);
    final r33 = R_3_6.entry(2, 2);
    
    final s_j4 = math.sqrt(r13 * r13 + r23 * r23);
    final j4 = math.atan2(s_j4, r33);
    
    double j3, j5;
    
    if (s_j4.abs() < 1e-6) {
      j3 = 0.0;
      final r11 = R_3_6.entry(0, 0);
      final r12 = R_3_6.entry(0, 1);
      j5 = math.atan2(-r12, r11);
    } else {
      j3 = math.atan2(r23 / s_j4, r13 / s_j4);
      j5 = math.atan2(r32 / s_j4, -r31 / s_j4);
    }
    
    return [vm.degrees(j0), vm.degrees(j1), vm.degrees(j2), vm.degrees(j3), vm.degrees(j4), vm.degrees(j5)];
  } catch (e) {
    print("Error during IK calculation: $e");
    return null;
  }
}

/// 只重新計算手腕關節 (j3, j4, j5) 的角度，保持手臂位置不變。
List<double>? recalculateWristOnlyIK(Map<String, double> targetIKState, List<double> currentAngles) {
  try {
    // 1. 使用當前固定的前三軸角度 (j0, j1, j2)
    final j0_rad = vm.radians(currentAngles[0]);
    final j1_rad = vm.radians(currentAngles[1]);
    final j2_rad = vm.radians(currentAngles[2]);

    // 2. 計算由這三軸決定的姿態矩陣 R_0_3
    final T_0_1 = _dhTransformMatrix(j0_rad, _dhParams['alpha']![0], _dhParams['a']![0], _dhParams['d']![0]);
    final T_1_2 = _dhTransformMatrix(j1_rad, _dhParams['alpha']![1], _dhParams['a']![1], _dhParams['d']![1]);
    final T_2_3 = _dhTransformMatrix(j2_rad, _dhParams['alpha']![2], _dhParams['a']![2], _dhParams['d']![2]);
    final T_0_3 = T_0_1 * T_1_2 * T_2_3;
    final R_0_3 = T_0_3.getRotation();
    
    // 3. 獲取新的目標姿態 R_0_6
    final R_0_6_new = _eulerToRotMatrix(
        targetIKState['rx']!, targetIKState['rz']!, targetIKState['ry']!);

    // 4. 求解出手腕所需的相對姿態 R_3_6
    final R_3_6 = R_0_3.transposed() * R_0_6_new;

    // 5. 從 R_3_6 中提取 j3, j4, j5 (邏輯同上)
    final r13 = R_3_6.entry(0, 2);
    final r23 = R_3_6.entry(1, 2);
    final r31 = R_3_6.entry(2, 0);
    final r32 = R_3_6.entry(2, 1);
    final r33 = R_3_6.entry(2, 2);
    
    final s_j4 = math.sqrt(r13 * r13 + r23 * r23);
    final j4_rad = math.atan2(s_j4, r33);
    
    double j3_rad, j5_rad;
    
    if (s_j4.abs() < 1e-6) {
      j3_rad = 0.0;
      final r11 = R_3_6.entry(0, 0);
      final r12 = R_3_6.entry(0, 1);
      j5_rad = math.atan2(-r12, r11);
    } else {
      j3_rad = math.atan2(r23 / s_j4, r13 / s_j4);
      j5_rad = math.atan2(r32 / s_j4, -r31 / s_j4);
    }
    
    // 6. 組合固定的舊角度和新計算出的手腕角度
    return [
      currentAngles[0], // j0 (不變)
      currentAngles[1], // j1 (不變)
      currentAngles[2], // j2 (不變)
      vm.degrees(j3_rad),
      vm.degrees(j4_rad),
      vm.degrees(j5_rad),
    ];
  } catch(e) {
    print("Error during wrist-only IK calculation: $e");
    return null;
  }
}

// =======================================================
// ========== END OF KINEMATICS IMPLEMENTATION ===========
// =======================================================


// --- LiveKit Receiver Widget (Unchanged) ---
class LiveKitReceiverWidget extends StatefulWidget {
  final String url;
  final String token;
  const LiveKitReceiverWidget({Key? key, required this.url, required this.token})
      : super(key: key);

  @override
  _LiveKitReceiverWidgetState createState() => _LiveKitReceiverWidgetState();
}

class _LiveKitReceiverWidgetState extends State<LiveKitReceiverWidget> {
  // ... (LiveKitReceiverWidget code remains completely unchanged)
  lk.Room? _room;
  lk.RemoteVideoTrack? _videoTrack;
  bool _connecting = false;
  String? _connectionError;
  Function? _trackSubscribedDisposer;
  Function? _roomDisposer;

  @override
  void initState() {
    super.initState();
    if (widget.token.isNotEmpty) {
       WidgetsBinding.instance.addPostFrameCallback((_) => _connectRoom());
    }
  }

  @override
  void didUpdateWidget(covariant LiveKitReceiverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url || widget.token != oldWidget.token) {
       _disconnectRoom().then((_) {
         if (widget.token.isNotEmpty && mounted) {
           _connectRoom();
         }
       });
    }
  }

  @override
  void dispose() {
    _disconnectRoom();
    super.dispose();
  }

  Future<void> _disconnectRoom() async {
     _roomDisposer?.call();
     _trackSubscribedDisposer?.call();
     if (_room != null) {
       await _room?.disconnect();
     }
     _room = null;
     if (mounted) {
         setState(() { _videoTrack = null; });
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
       _roomDisposer = room.events.listen((event) { if (mounted) setState(() {}); if (event is lk.RoomDisconnectedEvent) { if (mounted) setState(() { _videoTrack = null; }); } });
       _trackSubscribedDisposer = room.events.on<lk.TrackSubscribedEvent>((event) { if (event.track is lk.RemoteVideoTrack && mounted) { setState(() => _videoTrack = event.track as lk.RemoteVideoTrack); } });
       await room.connect( widget.url, widget.token, roomOptions: const lk.RoomOptions( adaptiveStream: true, dynacast: true,),);
       if (mounted && _videoTrack == null && room.connectionState == lk.ConnectionState.connected) { _checkForExistingTracks(room); }
       if (mounted) setState(() => _connecting = false);
     } catch (e) {
       if (mounted) { setState(() { _connecting = false; _connectionError = 'Connection failed: $e'; }); }
       await _disconnectRoom();
     }
  }

  void _checkForExistingTracks(lk.Room room) {
     for (final participant in room.remoteParticipants.values) {
       for (final pub in participant.videoTrackPublications) {
         if (pub.track != null && pub.track is lk.RemoteVideoTrack) {
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
    else if (_videoTrack != null) { content = lk.VideoTrackRenderer(_videoTrack!); }
    else if (_room?.connectionState == lk.ConnectionState.connected) { content = const Center(child: Text('Connected, waiting for video stream...', style: TextStyle(color: Colors.grey))); }
    else { content = Center( child: Column( mainAxisAlignment: MainAxisAlignment.center, children: [ const Text('Stream unavailable', style: TextStyle(color: Colors.grey)), const SizedBox(height: 15), if (_room?.connectionState != lk.ConnectionState.connecting && widget.token.isNotEmpty) ElevatedButton.icon( icon: const Icon(Icons.refresh), label: const Text("Connect Stream"), onPressed: _connectRoom, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[700]),), if (widget.token.isEmpty) const Text('Missing connection token.', style: TextStyle(color: Colors.orange)),],)); }
    return Container( color: Colors.black, width: double.infinity, height: double.infinity, child: content,);
  }
}

// === NEW WIDGET FOR BUTTON FEEDBACK ===
/// A stateful button that provides visual feedback on press.
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
  // --- LiveKit & UI State (Unchanged) ---
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  Key _receiverKey = UniqueKey();
  String? _fetchedLivekitToken;
  bool _isFetchingToken = false;
  String? _tokenError;
  int _selectedControlTabIndex = 0;
  final List<bool> _isSelected = [true, false];
  
  // --- Gamepad State Management ---
  late Map<String, double> _ikState;
  late int _clawValue;
  
  // State for storing last known joint angles for smooth movement
  List<double>? _lastKnownJointAngles;

  // --- State for Sliders page (Unchanged) ---
  double _arm2SliderValA = 90, _arm2SliderValB = 90, _arm2SliderValC = 90;
  double _arm2SliderValD = 90, _arm2SliderValE = 90, _arm2SliderValF = 90;

  final Map<String, DateTime> _lastSendTime = {};
  final Duration _throttleDuration = const Duration(milliseconds: 50);

  void _publishThrottled(MqttService mqttService, String controlId, String topic, String payload) {
    final now = DateTime.now();
    if (_lastSendTime[controlId] == null || now.difference(_lastSendTime[controlId]!) > _throttleDuration) {
      mqttService.publish(topic, payload);
      _lastSendTime[controlId] = now;
    }
  }

   @override
   void initState() {
     super.initState();
     _ikState = Map<String, double>.from(IKConfig.resetState);
     _clawValue = IKConfig.clawMax;
     
     _lastKnownJointAngles = calculateInverseKinematics(
       _ikState['x']!, _ikState['y']!, _ikState['z']!,
       _ikState['rx']!, _ikState['rz']!, _ikState['ry']!
     ) ?? [0,0,0,0,0,0];

     WidgetsBinding.instance.addPostFrameCallback((_) {
         final mqttService = ref.read(mqttServiceProvider);
         if (mqttService.connectionState != MqttConnectionState.connected && mqttService.connectionState != MqttConnectionState.connecting) {
            mqttService.connect();
         }
         mqttService.setOnMessageReceivedCallback(_handleMqttMessage);
         _publishNewAngles(mqttService, _lastKnownJointAngles);
     });
     _fetchAndSetLiveKitToken();
   }

  @override
  void dispose() {
    // Timer is now managed inside FeedbackControlButton, no need to cancel here.
    super.dispose();
  }

   void _handleMqttMessage(String topic, String payload) {
       print("MQTT Message Received in UI: $topic -> $payload");
   }

   Future<void> _fetchAndSetLiveKitToken() async {
     // ... (This function remains unchanged)
     if (_isFetchingToken) return;
     setState(() { _isFetchingToken = true; _tokenError = null; _fetchedLivekitToken = null; });
     final String tokenApiUrl = 'https://roger01.site/get-livekit-token';
     try {
       final response = await http.get(Uri.parse(tokenApiUrl)).timeout(const Duration(seconds: 15));
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
    // ... (This function remains unchanged)
    TextEditingController urlController = TextEditingController(text: livekitUrl);
    await showDialog(context: context, builder: (context) => AlertDialog(title: const Text("Modify Streaming URL"), content: TextField( controller: urlController, decoration: const InputDecoration(labelText: "LiveKit URL"),), actions: [ TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel"),), TextButton(onPressed: () { if (mounted) { final newUrl = urlController.text.trim(); if (newUrl.isNotEmpty && newUrl != livekitUrl) { setState(() { livekitUrl = newUrl; _receiverKey = UniqueKey(); }); } } Navigator.of(context).pop(); }, child: const Text("Save URL"),), ],),);
   }

  Widget _buildVerticalSlider({
    required String label, required String controlId, required double value,
    required ValueChanged<double> onChanged,
  }) {
    // ... (This function remains unchanged)
    return Padding( padding: const EdgeInsets.symmetric(horizontal: 4.0), child: Column( mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [ Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center,), const SizedBox(height: 8), SizedBox( height: 180, child: RotatedBox( quarterTurns: -1, child: Slider( value: value, min: 0, max: 180, divisions: 180, label: "${value.toInt()}°", onChanged: onChanged,),),), const SizedBox(height: 4), Text("${value.toInt()}°", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),), ],),);
  }

  /// Unwraps angles to prevent 360-degree jumps by choosing the closest angle.
  List<double> _unwrapAngles(List<double> newAngles, List<double> previousAngles) {
    final unwrapped = List<double>.from(newAngles);
    for (int i = 0; i < unwrapped.length; i++) {
      double diff = unwrapped[i] - previousAngles[i];
      if (diff > 180) {
        unwrapped[i] -= 360;
      } else if (diff < -180) {
        unwrapped[i] += 360;
      }
    }
    return unwrapped;
  }

  /// Centralized function to publish angles and update state.
  void _publishNewAngles(MqttService mqttService, List<double>? newAngles) {
    if (newAngles == null) {
      print("IK Solution not found for state: $_ikState");
      return;
    }

    final unwrappedAngles = _lastKnownJointAngles != null
        ? _unwrapAngles(newAngles, _lastKnownJointAngles!)
        : newAngles;

    _lastKnownJointAngles = unwrappedAngles;

    final payload = "jm ${unwrappedAngles[0].round()} ${unwrappedAngles[1].round()} ${unwrappedAngles[2].round()} ${unwrappedAngles[3].round()} ${unwrappedAngles[4].round()} ${unwrappedAngles[5].round()}";
    _publishThrottled(mqttService, 'jm_gamepad', IKConfig.jmTopic, payload);
    print("Publishing: $payload");
  }


  /// Handles arm POSITION changes (x, y, z).
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

    final newAngles = calculateInverseKinematics(
        _ikState['x']!, _ikState['y']!, _ikState['z']!,
        _ikState['rx']!, _ikState['rz']!, _ikState['ry']!);
    _publishNewAngles(mqttService, newAngles);
  }
  
  /// Handles arm ORIENTATION changes (ry).
  void _setIKRotation(MqttService mqttService, { required double newRy }) {
      setState(() { _ikState['ry'] = newRy; });

      if (_lastKnownJointAngles == null) return; // Safety check

      final newAngles = recalculateWristOnlyIK(_ikState, _lastKnownJointAngles!);
      _publishNewAngles(mqttService, newAngles);
  }

  void _incrementClaw(MqttService mqttService, { required bool isPositive }) {
    setState(() {
      int change = isPositive ? IKConfig.clawStepValue : -IKConfig.clawStepValue;
      _clawValue = (_clawValue + change).clamp(IKConfig.clawMin, IKConfig.clawMax);
    });
    final payload = 'clm $_clawValue';
    _publishThrottled(mqttService, 'claw_gamepad', IKConfig.clawTopic, payload);
    print("Publishing: $payload");
  }

  void _resetIKStateAndPublish(MqttService mqttService) {
    setState(() {
      _ikState = Map<String, double>.from(IKConfig.resetState);
      _clawValue = IKConfig.clawMax;
    });
    final newAngles = calculateInverseKinematics(
      _ikState['x']!, _ikState['y']!, _ikState['z']!,
      _ikState['rx']!, _ikState['rz']!, _ikState['ry']!
    );
    // When resetting, we don't unwrap, we just set the new state directly.
    _lastKnownJointAngles = newAngles ?? _lastKnownJointAngles;
    _publishNewAngles(mqttService, newAngles);

    mqttService.publish(IKConfig.clawTopic, 'clm $_clawValue');
    print("IK state and claw have been reset to default values.");
  }
  
  
  // --- Gamepad Controls Widget ---
  Widget _buildGamepadControls(MqttService mqttService) {
    // Responsive sizing
    final screenWidth = MediaQuery.of(context).size.width;
    final double arrowIconSize = screenWidth < 360 ? 20.0 : 28.0;
    final double addRemoveIconSize = screenWidth < 360 ? 18.0 : 24.0;
    final double innerPadding = screenWidth < 360 ? 8.0 : 12.0; // Increased padding for better touch area
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
            // --- Left Column: Forward/Back (X) & Claw Orientation (RY) ---
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
                        icon: Icon(Icons.align_horizontal_right, size: addRemoveIconSize, color: Theme.of(context).primaryColor), // Claw Forward
                        onUpdate: () => _setIKRotation(mqttService, newRy: IKConfig.clawUpRad),
                      ),
                      SizedBox(width: spacerWidth),
                      FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.align_vertical_top, size: addRemoveIconSize, color: Theme.of(context).primaryColor), // Claw Down
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
            
            // --- Center Column: Claw Open/Close (Incremental) ---
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Claw", style: TextStyle(fontWeight: FontWeight.bold, fontSize: clawLabelSize)),
                  SizedBox(height: screenWidth < 360 ? 6 : 8),
                   FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.add, size: addRemoveIconSize, color: Theme.of(context).primaryColor), // Open
                    onUpdate: () => _incrementClaw(mqttService, isPositive: true),
                  ),
                  SizedBox(height: screenWidth < 360 ? 8 : 12),
                   FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.remove, size: addRemoveIconSize, color: Theme.of(context).primaryColor), // Close
                    onUpdate: () => _incrementClaw(mqttService, isPositive: false),
                  ),
                ],
              ),
            ),

            // --- Right Column: Up/Down (Z) & Left/Right (Y) ---
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.arrow_upward, size: arrowIconSize, color: Theme.of(context).primaryColor), // Up
                    onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadVertical']!, step: IKConfig.stepZ),
                  ),
                  SizedBox(height: screenWidth < 360 ? 3 : 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.arrow_back, size: arrowIconSize, color: Theme.of(context).primaryColor), // Left
                        onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadHorizontal']!, step: -IKConfig.stepY),
                      ),
                      SizedBox(width: spacerWidth),
                      FeedbackControlButton(
                        padding: innerPadding,
                        icon: Icon(Icons.arrow_forward, size: arrowIconSize, color: Theme.of(context).primaryColor), // Right
                        onUpdate: () => _incrementIKValue(mqttService, axis: IKConfig.gamepadAxisMapping['rightPadHorizontal']!, step: IKConfig.stepY),
                      ),
                    ],
                  ),
                  SizedBox(height: screenWidth < 360 ? 3 : 4),
                  FeedbackControlButton(
                    padding: innerPadding,
                    icon: Icon(Icons.arrow_downward, size: arrowIconSize, color: Theme.of(context).primaryColor), // Down
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

  // --- Unchanged Slider Control page ---
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
                const Text("Arm 2 Control (Sliders)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() => _clawValue = IKConfig.clawMax);
                    mqttService.publish(IKConfig.clawTopic, 'clm ${IKConfig.clawMax}');
                  },
                  child: const Text("Open"),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _clawValue = IKConfig.clawMin);
                    mqttService.publish(IKConfig.clawTopic, 'clm ${IKConfig.clawMin}');
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
                      String controlId = 'arm2_slider_$label';
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
                          final topic = "servo/arm2/$label";
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
    // ... (This function remains unchanged)
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
     else { liveKitContentArea = LiveKitReceiverWidget( key: _receiverKey, url: livekitUrl, token: _fetchedLivekitToken!,); }

    return Scaffold(
      appBar: AppBar(
         title: const Text("Robotic Arm Controller"),
         actions: [
         IconButton(
           icon: const Icon(Icons.flip_camera_android_outlined),
           tooltip: "Open Publisher Page",
           onPressed: () async {
             final publisherUrl = Uri.parse('https://roger01.site/publisher.html');
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
         IconButton(icon: const Icon(Icons.vpn_key_sharp), tooltip: "Refresh LiveKit Token", onPressed: _fetchAndSetLiveKitToken,),
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
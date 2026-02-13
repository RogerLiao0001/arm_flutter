//for math
//夾起：setState(() => _motorAngles[clawMotorLabel] = 55);
// lib/ui/motor_control_page.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode/Decode
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
// --- NEW: Centralized Configuration Class for Gamepad Buttons ---
// =========================================================================
class MotorControlConfig {
  /// The label of the motor to control (e.g., 'a', 'l', 'z').
  final String motorLabel;
  
  /// The initial value of the motor when the app starts or resets.
  final double initialValue;
  
  /// The value to change per button press. Use a negative value to reverse direction.
  final double stepValue;
  
  /// The minimum angle limit (optional).
  final double? minLimit;

  /// The maximum angle limit (optional).
  final double? maxLimit;

  const MotorControlConfig({
    required this.motorLabel,
    required this.initialValue,
    required this.stepValue,
    this.minLimit,
    this.maxLimit,
  });
}

// --- LiveKit Receiver Widget (Unchanged) ---
class LiveKitReceiverWidget extends StatefulWidget {
  // ... (LiveKitReceiverWidget code remains completely unchanged)
  final String url;
  final String token;
  const LiveKitReceiverWidget({Key? key, required this.url, required this.token})
      : super(key: key);

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

// --- Main Control Page ---
class MotorControlPage extends ConsumerStatefulWidget {
  const MotorControlPage({Key? key}) : super(key: key);

  @override
  ConsumerState<MotorControlPage> createState() => _MotorControlPageState();
}

class _MotorControlPageState extends ConsumerState<MotorControlPage> {

  // =========================================================================
  // --- NEW: Centralized Gamepad Motor Configuration ---
  // =========================================================================
  final Map<String, MotorControlConfig> _gamepadConfigs = {
    // Left D-Pad: Up/Down
    'dPadVertical': const MotorControlConfig(
      motorLabel: 'l',
      initialValue: 200.0,
      stepValue: 5.0, // Positive for Up
      minLimit: 0.0,
      maxLimit: 360.0,
    ),
    // Left D-Pad: Left/Right
    'dPadHorizontal': const MotorControlConfig(
      motorLabel: 'a',
      initialValue: 90.0,
      stepValue: 2.0, // Positive for Right
      minLimit: 45.0,
      maxLimit: 135.0,
    ),
    // Right Pad: Up/Down
    'forwardBack': const MotorControlConfig(
      motorLabel: 'z',
      initialValue: 100.0,
      stepValue: 5.0, // Positive for Up
      minLimit: 0, // Space reserved for future limits
      maxLimit: 360,
    ),
    // Center Claw (special case, not incremental)
    'claw': const MotorControlConfig(
      motorLabel: 'h',
      initialValue: 100.0, // Open state
      stepValue: 55, // Not used
    ),
  };
  // =========================================================================

  // --- LiveKit & UI State (Unchanged) ---
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  Key _receiverKey = UniqueKey();
  String? _fetchedLivekitToken;
  bool _isFetchingToken = false;
  String? _tokenError;
  int _selectedControlTabIndex = 0;
  final List<bool> _isSelected = [true, false];
  Timer? _motorUpdateTimer;
  
  // --- NEW: Centralized Motor State Management ---
  Map<String, double> _motorAngles = {};

  // --- Slider Page State (Remains separate) ---
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
     // --- NEW: Initialize motor angles from the centralized configuration ---
     _gamepadConfigs.forEach((key, config) {
       _motorAngles[config.motorLabel] = config.initialValue;
     });
     // Manually add other motors needed for reset logic
     _motorAngles['b'] = 90.0;
     _motorAngles['d'] = 83.0;
     _motorAngles['f'] = 90.0;
     // The original 'c' and 'e' motors are no longer on gamepad but need reset values
     _motorAngles['c'] = 90.0;
     _motorAngles['e'] = 90.0;

     super.initState();
      WidgetsBinding.instance.addPostFrameCallback((_) {
          final mqttService = ref.read(mqttServiceProvider);
          if (mqttService.connectionState != MqttConnectionState.connected && mqttService.connectionState != MqttConnectionState.connecting) {
             mqttService.connect();
          }
          mqttService.setOnMessageReceivedCallback(_handleMqttMessage);
      });
     _fetchAndSetLiveKitToken();
   }

  @override
  void dispose() {
    _motorUpdateTimer?.cancel();
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
     await showDialog(
       context: context,
       builder: (context) => AlertDialog(
         title: const Text("Modify Streaming URL"),
         content: TextField( controller: urlController, decoration: const InputDecoration(labelText: "LiveKit URL"),),
         actions: [
           TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel"),),
           TextButton(
             onPressed: () {
               if (mounted) {
                 final newUrl = urlController.text.trim();
                 if (newUrl.isNotEmpty && newUrl != livekitUrl) {
                    setState(() { livekitUrl = newUrl; _receiverKey = UniqueKey(); });
                 }
               }
               Navigator.of(context).pop();
             },
             child: const Text("Save URL"),
           ),
         ],
       ),
     );
   }

  Widget _buildVerticalSlider({
    required String label, required String controlId, required double value,
    required ValueChanged<double> onChanged,
  }) {
    // ... (This function remains unchanged)
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Column( mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center,),
          const SizedBox(height: 8),
          SizedBox( height: 180, child: RotatedBox( quarterTurns: -1, child: Slider(
                value: value, min: 0, max: 180, divisions: 180,
                label: "${value.toInt()}°",
                onChanged: onChanged,
            ),),),
          const SizedBox(height: 4),
          Text("${value.toInt()}°", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),),
        ],
      ),
    );
  }

  // --- NEW: Generic motor update function ---
  void _updateMotorValue(MqttService mqttService, {
    required String configKey,
    required bool isPositive, // True for Up/Right, False for Down/Left
  }) {
    final config = _gamepadConfigs[configKey]!;
    final motorLabel = config.motorLabel;
    
    // Determine the change in value based on direction
    final double change = isPositive ? config.stepValue : -config.stepValue;

    setState(() {
      double currentValue = _motorAngles[motorLabel] ?? config.initialValue;
      double newValue = currentValue + change;
      
      if (config.minLimit != null && config.maxLimit != null) {
        newValue = newValue.clamp(config.minLimit!, config.maxLimit!);
      }
      
      _motorAngles[motorLabel] = newValue;
    });

    final topic = "servo/arm2/$motorLabel";
    final payload = jsonEncode({"angle": _motorAngles[motorLabel]!.round()});
    _publishThrottled(mqttService, 'gamepad_$motorLabel', topic, payload);
  }

  void _resetGamepadToDefaults(MqttService mqttService) {
    setState(() {
      // Reset all motor angles in the state map based on config
      _gamepadConfigs.forEach((key, config) {
        _motorAngles[config.motorLabel] = config.initialValue;
      });
      // Reset non-gamepad motors
      _motorAngles['b'] = 90.0; _motorAngles['d'] = 83.0; _motorAngles['f'] = 90.0;
      _motorAngles['c'] = 90.0; _motorAngles['e'] = 90.0;

      // Also reset slider values for UI consistency
      _arm2SliderValA = _motorAngles['a']!; _arm2SliderValB = 90.0;
      _arm2SliderValC = 90.0; _arm2SliderValD = 83.0;
      _arm2SliderValE = 90.0; _arm2SliderValF = 90.0;
    });

    // Publish reset commands for all motors
    _motorAngles.forEach((label, value) {
      mqttService.publish("servo/arm2/$label", jsonEncode({"angle": value.toInt()}));
    });
    
    print("All arm 2 motors have been reset to default values.");
  }
  
  // UNCHANGED: This widget's structure is preserved.
  Widget _buildContinuousControlButton({ required IconData icon, required Function() onUpdate, }) {
    return GestureDetector(
      onTapDown: (details) {
        _motorUpdateTimer?.cancel();
        onUpdate();
        _motorUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
          onUpdate();
        });
      },
      onTapUp: (details) => _motorUpdateTimer?.cancel(),
      onTapCancel: () => _motorUpdateTimer?.cancel(),
      child: Card(
        elevation: 3.0,
        shape: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Icon(icon, size: 28.0, color: Theme.of(context).primaryColor),
        ),
      ),
    );
  }

  // UNCHANGED: The entire widget tree of this build method is preserved from your provided code.
  // The ONLY change is inside the `onUpdate` callbacks.
  Widget _buildGamepadControls(MqttService mqttService) {
    // The state for the claw button is now derived from the central map.
    final clawMotorLabel = _gamepadConfigs['claw']!.motorLabel;
    bool isClawOpen = (_motorAngles[clawMotorLabel] ?? _gamepadConfigs['claw']!.initialValue) == 100.0;

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // --- Left Column: Directional Pad ---
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildContinuousControlButton(
                    icon: Icons.arrow_upward,
                    // MODIFIED: Pointing to new generic function
                    onUpdate: () => _updateMotorValue(mqttService, configKey: 'dPadVertical', isPositive: true),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildContinuousControlButton(
                        icon: Icons.arrow_back,
                        // MODIFIED: Pointing to new generic function
                        onUpdate: () => _updateMotorValue(mqttService, configKey: 'dPadHorizontal', isPositive: false),
                      ),
                      const SizedBox(width: 48),
                      _buildContinuousControlButton(
                        icon: Icons.arrow_forward,
                        // MODIFIED: Pointing to new generic function
                        onUpdate: () => _updateMotorValue(mqttService, configKey: 'dPadHorizontal', isPositive: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _buildContinuousControlButton(
                    icon: Icons.arrow_downward,
                    // MODIFIED: Pointing to new generic function
                    onUpdate: () => _updateMotorValue(mqttService, configKey: 'dPadVertical', isPositive: false),
                  ),
                ],
              ),
            ),
            // --- Center Column: Claw Control ---
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Claw", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    style: (isClawOpen ? ElevatedButton.styleFrom(minimumSize: const Size(80, 40)) : OutlinedButton.styleFrom(minimumSize: const Size(80, 40))),
                    // MODIFIED: Uses central state
                    onPressed: () {
                      setState(() => _motorAngles[clawMotorLabel] = 100.0);
                      mqttService.publish('servo/arm2/$clawMotorLabel', jsonEncode({"angle": 100}));
                    },
                    child: const Text("Open"),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: (!isClawOpen ? ElevatedButton.styleFrom(minimumSize: const Size(80, 40)) : OutlinedButton.styleFrom(minimumSize: const Size(80, 40))),
                    // MODIFIED: Uses central state
                    onPressed: () {
                      setState(() => _motorAngles[clawMotorLabel] = 55);
                      mqttService.publish('servo/arm2/$clawMotorLabel', jsonEncode({"angle": 0}));
                    },
                    child: const Text("Close"),
                  ),
                ],
              ),
            ),
            // --- Right Column: Forward/Back Control ---
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Up", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 4),
                  _buildContinuousControlButton(
                    icon: Icons.arrow_upward,
                    // MODIFIED: Pointing to new generic function
                    onUpdate: () => _updateMotorValue(mqttService, configKey: 'forwardBack', isPositive: true),
                  ),
                  const SizedBox(height: 32),
                  _buildContinuousControlButton(
                    icon: Icons.arrow_downward,
                    // MODIFIED: Pointing to new generic function
                    onUpdate: () => _updateMotorValue(mqttService, configKey: 'forwardBack', isPositive: false),
                  ),
                  const SizedBox(height: 4),
                  const Text("Down", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Unchanged Slider Control page
  Widget _buildArm2Controls(MqttService mqttService) {
     final Map<int, String> arm2Labels = { 1: 'a', 2: 'b', 3: 'c', 4: 'd', 5: 'e', 6: 'f' };
     final Map<int, String> arm2MotorTypes = { 1: 'Servo', 2: 'Servo', 3: 'Servo', 4: 'Stepper', 5: 'Stepper', 6: 'Stepper' };
     final clawMotorLabel = _gamepadConfigs['claw']!.motorLabel;

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
                    setState(() => _motorAngles[clawMotorLabel] = 100);
                    mqttService.publish('servo/arm2/$clawMotorLabel', jsonEncode({"angle": 100}));
                  },
                  child: const Text("Open"),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _motorAngles[clawMotorLabel] = 55);
                    mqttService.publish('servo/arm2/$clawMotorLabel', jsonEncode({"angle": 55}));
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
                    onPressed: () => _resetGamepadToDefaults(mqttService),
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
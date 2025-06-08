// ui/motor_control_page.dart
//v0

import 'dart:async';
import 'dart:convert'; // For jsonEncode/Decode
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk; // Use prefix
import 'package:mqtt_client/mqtt_client.dart' show MqttConnectionState;
import 'package:http/http.dart' as http; // For fetching token
import 'package:flutter_animate/flutter_animate.dart'; // For animations

// Import provider and service definitions
import '../providers/arm_controller_provider.dart';
import '../services/mqtt_service.dart';

// --- LiveKit Receiver Widget (保持不變，已修正) ---
class LiveKitReceiverWidget extends StatefulWidget {
  // ... (LiveKitReceiverWidget 程式碼保持上次修正後的版本) ...
  final String url;
  final String token; // Token is now required
  const LiveKitReceiverWidget({Key? key, required this.url, required this.token})
      : super(key: key);

  @override
  _LiveKitReceiverWidgetState createState() => _LiveKitReceiverWidgetState();
}

class _LiveKitReceiverWidgetState extends State<LiveKitReceiverWidget> {
  lk.Room? _room;
  lk.RemoteVideoTrack? _videoTrack;
  bool _connecting = false;
  String? _connectionError; // Store connection error message
  Function? _trackSubscribedDisposer;
  Function? _roomDisposer;

  @override
  void initState() {
    super.initState();
    if (widget.token.isNotEmpty) {
       WidgetsBinding.instance.addPostFrameCallback((_) => _connectRoom());
    } else {
       print("LiveKitReceiverWidget: No token provided on init.");
    }
  }

  @override
  void didUpdateWidget(covariant LiveKitReceiverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url || widget.token != oldWidget.token) {
      print("LiveKitReceiverWidget: URL or Token changed, reconnecting...");
       _disconnectRoom().then((_) {
         if (widget.token.isNotEmpty && mounted) {
           _connectRoom();
         }
       });
    }
  }

  @override
  void dispose() {
    print("LiveKitReceiverWidget disposing...");
    _disconnectRoom();
    super.dispose();
  }

  Future<void> _disconnectRoom() async {
     print("LiveKitReceiverWidget: Disconnecting...");
     _roomDisposer?.call();
     _trackSubscribedDisposer?.call();
     // Add null check before disconnecting
     if (_room != null) {
       await _room?.disconnect();
     }
     _room = null;
     if (mounted) {
         setState(() { _videoTrack = null; });
     }
  }

  Future<void> _connectRoom() async {
     if (_connecting) { print("LiveKit connection already in progress."); return; }
     if (_room?.connectionState == lk.ConnectionState.connected || _room?.connectionState == lk.ConnectionState.connecting) { print("LiveKit room already connected or connecting."); return; }
     if (widget.token.isEmpty) { print("Cannot connect LiveKit: Token is empty."); setState(() { _connectionError = "Token is missing."; }); return; }

     setState(() { _connecting = true; _videoTrack = null; _connectionError = null; });
     print('Attempting to connect to LiveKit room: ${widget.url}');

     try {
       await _disconnectRoom(); // Ensure clean state before new connection

       final room = lk.Room();
       _room = room;

       _roomDisposer = room.events.listen((event) { if (mounted) setState(() {}); if (event is lk.RoomDisconnectedEvent) { if (mounted) setState(() { _videoTrack = null; }); } });
       _trackSubscribedDisposer = room.events.on<lk.TrackSubscribedEvent>((event) { if (event.track is lk.RemoteVideoTrack && mounted) { setState(() => _videoTrack = event.track as lk.RemoteVideoTrack); } });

       await room.connect( widget.url, widget.token, roomOptions: const lk.RoomOptions( adaptiveStream: true, dynacast: true,),);
       print('Successfully initiated connection to LiveKit room: ${room.name}');

       if (mounted && _videoTrack == null && room.connectionState == lk.ConnectionState.connected) { _checkForExistingTracks(room); }
       if (mounted) setState(() => _connecting = false);

     } catch (e) {
       print('LiveKit connection error: $e');
       if (mounted) { setState(() { _connecting = false; _connectionError = 'Connection failed: $e'; }); }
       await _disconnectRoom();
     }
  }

  void _checkForExistingTracks(lk.Room room) {
     print("Checking existing participants for video tracks...");
     for (final participant in room.remoteParticipants.values) {
       for (final pub in participant.videoTrackPublications) {
         if (pub.track != null && pub.track is lk.RemoteVideoTrack) { // Corrected check
           print('Found existing video track from: ${participant.identity}.');
           if (mounted) { setState(() => _videoTrack = pub.track as lk.RemoteVideoTrack); return; }
         }
       }
     }
     print("No initial video track found among existing participants.");
   }

   @override
  Widget build(BuildContext context) {
    Widget content;
    if (_connecting) { 
      content = const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF0078D4),
          strokeWidth: 3,
        )
      ); 
    }
    else if (_connectionError != null) { 
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0), 
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center, 
            children: [
              Icon(Icons.error_outline, color: Colors.red[700], size: 40),
              const SizedBox(height: 10),
              Text('LiveKit Error:', 
                style: TextStyle(color: Colors.red[700], fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              Text(_connectionError!, 
                textAlign: TextAlign.center, 
                style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text("Retry Connection"),
                onPressed: widget.token.isNotEmpty ? _connectRoom : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0078D4),
                  foregroundColor: Colors.white,
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              )
            ],
          ),
        ),
      ); 
    }
    else if (_videoTrack != null) { 
      content = Stack(
        children: [
          lk.VideoTrackRenderer(_videoTrack!),
          // Add a subtle gradient overlay at the bottom for better visibility
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 60,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withOpacity(0.3), Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      ); 
    }
    else if (_room?.connectionState == lk.ConnectionState.connected) { 
      content = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                color: Color(0xFF0078D4),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Connected, waiting for video stream...',
              style: TextStyle(
                color: Colors.black54,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ); 
    }
    else { 
      content = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              'Video stream unavailable',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 20),
            if (_room?.connectionState != lk.ConnectionState.connecting && widget.token.isNotEmpty)
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text("Connect Stream"),
                onPressed: _connectRoom,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0078D4),
                  foregroundColor: Colors.white,
                  elevation: 2,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            if (widget.token.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Missing connection token',
                  style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w500),
                ),
              ),
          ],
        ),
      ); 
    }
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      width: double.infinity,
      height: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: content,
      ),
    );
  }
}

// --- Compact Vertical Slider ---
class CompactVerticalSlider extends StatefulWidget {
  final String label;
  final String controlId;
  final double value;
  final ValueChanged<double> onChanged;
  final Color accentColor;
  final bool showPresets;

  const CompactVerticalSlider({
    Key? key,
    required this.label,
    required this.controlId,
    required this.value,
    required this.onChanged,
    this.accentColor = const Color(0xFF0078D4),
    this.showPresets = true,
  }) : super(key: key);

  @override
  State<CompactVerticalSlider> createState() => _CompactVerticalSliderState();
}

class _CompactVerticalSliderState extends State<CompactVerticalSlider> {
  double _localValue = 90;
  bool _isActive = false;

  @override
  void initState() {
    super.initState();
    _localValue = widget.value;
  }

  @override
  void didUpdateWidget(CompactVerticalSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && !_isActive) {
      _localValue = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _isActive ? widget.accentColor : Colors.black87,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: RotatedBox(
            quarterTurns: -1,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 6,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                activeTrackColor: widget.accentColor,
                inactiveTrackColor: Colors.grey[300],
                thumbColor: widget.accentColor,
                overlayColor: widget.accentColor.withOpacity(0.2),
              ),
              child: Slider(
                value: _localValue,
                min: 0,
                max: 180,
                divisions: 180,
                label: "${_localValue.toInt()}°",
                onChanged: (value) {
                  setState(() {
                    _localValue = value;
                    _isActive = true;
                  });
                  widget.onChanged(value);
                },
                onChangeEnd: (value) {
                  setState(() {
                    _isActive = false;
                  });
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: _isActive 
              ? widget.accentColor.withOpacity(0.1) 
              : Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            "${_localValue.toInt()}°",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _isActive ? widget.accentColor : Colors.black87,
            ),
          ),
        ),
        if (widget.showPresets) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPresetButton(0),
              const SizedBox(width: 4),
              _buildPresetButton(90),
              const SizedBox(width: 4),
              _buildPresetButton(180),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildPresetButton(int angle) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _localValue = angle.toDouble();
          _isActive = true;
        });
        widget.onChanged(angle.toDouble());
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {
              _isActive = false;
            });
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: _localValue.toInt() == angle 
            ? widget.accentColor 
            : Colors.grey[200],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          "$angle°",
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: _localValue.toInt() == angle 
              ? Colors.white 
              : Colors.black87,
          ),
        ),
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

class _MotorControlPageState extends ConsumerState<MotorControlPage> with SingleTickerProviderStateMixin {
  // LiveKit settings
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  Key _receiverKey = UniqueKey();

  // Token Management State
  String? _fetchedLivekitToken;
  bool _isFetchingToken = false;
  String? _tokenError;

  // UI State
  int _selectedArm = 1;
  late TabController _tabController;
  bool _isVideoExpanded = false;

  // Arm 1 State
  double _arm1SliderVal1 = 90; double _arm1SliderVal2 = 90; double _arm1SliderVal3 = 90;
  double _arm1SliderVal4 = 90; double _arm1SliderVal5 = 90; bool _isElectromagnetOn = false;

  // Arm 2 State
  double _arm2SliderVal1 = 90; double _arm2SliderVal2 = 90; double _arm2SliderVal3 = 90;
  double _arm2SliderVal4 = 90; double _arm2SliderVal5 = 90; double _arm2SliderVal6 = 90;

  // --- *** Throttling State and Logic *** ---
  final Map<String, DateTime> _lastSendTime = {}; // Map to store last send time for each control
  final Duration _throttleDuration = const Duration(milliseconds: 50); // Throttle interval (e.g., 150ms)

  // Function to handle throttled MQTT publish
  void _publishThrottled(MqttService mqttService, String controlId, String topic, String payload) {
    final now = DateTime.now();
    // Check if enough time has passed since the last message for THIS control
    if (_lastSendTime[controlId] == null || now.difference(_lastSendTime[controlId]!) > _throttleDuration) {
      mqttService.publish(topic, payload);
      _lastSendTime[controlId] = now; // Update last send time
      // print("Published ($controlId): $topic -> $payload"); // Optional debug print
    } else {
      // print("Throttled ($controlId)"); // Optional debug print
    }
  }
  // --- *** End Throttling Logic *** ---

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _selectedArm = _tabController.index + 1;
        });
      }
    });
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final mqttService = ref.read(mqttServiceProvider);
      // Attempt initial MQTT connection if not already connecting/connected
      if (mqttService.connectionState != MqttConnectionState.connected && mqttService.connectionState != MqttConnectionState.connecting) {
         print("Initiating MQTT connection from initState...");
         mqttService.connect();
      } else {
         print("MQTT already connected or connecting on initState.");
      }
      // Setup MQTT message listener (regardless of initial connection state)
      mqttService.setOnMessageReceivedCallback(_handleMqttMessage);
    });
    _fetchAndSetLiveKitToken();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _handleMqttMessage(String topic, String payload) {
    print("MQTT Message Received in UI: $topic -> $payload");
    // TODO: Add logic to update UI based on received messages if needed
    // For example, if another controller changes a motor, update the slider visually
  }

  Future<void> _fetchAndSetLiveKitToken() async {
    if (_isFetchingToken) return;
    setState(() { _isFetchingToken = true; _tokenError = null; _fetchedLivekitToken = null; });

    final String tokenApiUrl = 'https://roger01.site/get-livekit-token'; // Your API URL
    print("Fetching LiveKit token from: $tokenApiUrl");

    try {
      final response = await http.get(Uri.parse(tokenApiUrl)).timeout(const Duration(seconds: 15));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final token = jsonResponse['token'];
        if (token != null && token is String && token.isNotEmpty) {
          print("Successfully fetched LiveKit token.");
          setState(() { _fetchedLivekitToken = token; _isFetchingToken = false; _receiverKey = UniqueKey(); });
        } else { throw Exception('Token invalid or not found in response'); }
      } else { throw Exception('Failed to load token (${response.statusCode}): ${response.body}'); }
    } catch (e) {
      print('Error fetching LiveKit token: $e');
      if (mounted) { setState(() { _tokenError = 'Token fetch failed.'; _isFetchingToken = false; _fetchedLivekitToken = null; _receiverKey = UniqueKey(); }); }
    }
  }

  Future<void> _editStreamingSettings() async {
    TextEditingController urlController = TextEditingController(text: livekitUrl);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Modify Streaming URL"),
        content: TextField(
          controller: urlController,
          decoration: const InputDecoration(labelText: "LiveKit URL"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              if (mounted) {
                final newUrl = urlController.text.trim();
                if (newUrl.isNotEmpty && newUrl != livekitUrl) {
                  setState(() { livekitUrl = newUrl; _receiverKey = UniqueKey(); });
                  print("LiveKit URL updated.");
                }
              }
              Navigator.of(context).pop();
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  // --- UI Builder Widgets ---

  // Arm 1 Controls Card
  Widget _buildArm1Controls(MqttService mqttService) {
    final List<Color> accentColors = [
      const Color(0xFF0078D4), // Microsoft Blue
      const Color(0xFF107C10), // Microsoft Green
      const Color(0xFF5C2D91), // Microsoft Purple
      const Color(0xFFD83B01), // Microsoft Orange
      const Color(0xFF00B7C3), // Microsoft Teal
    ];

    return Column(
      children: [
        // Electromagnet switch
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "Electromagnet",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: _isElectromagnetOn,
                activeColor: const Color(0xFF0078D4),
                activeTrackColor: const Color(0xFF0078D4).withOpacity(0.5),
                inactiveThumbColor: Colors.grey[300],
                inactiveTrackColor: Colors.grey[300],
                onChanged: (bool v) {
                  setState(() => _isElectromagnetOn = v);
                  // Publish Electromagnet state directly
                  final topic = "servo/magnet";
                  final payload = v ? "ON" : "OFF";
                  mqttService.publish(topic, payload);
                  _lastSendTime['arm1_magnet'] = DateTime.now();
                },
              ),
            ],
          ),
        ),
        
        // Motor sliders
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: CompactVerticalSlider(
                    label: "Motor 1",
                    controlId: 'arm1_1',
                    value: _arm1SliderVal1,
                    accentColor: accentColors[0],
                    onChanged: (v) {
                      setState(() => _arm1SliderVal1 = v);
                      final topic = "servo/1";
                      final payload = jsonEncode({"id": 1, "angle": v.toInt()});
                      _publishThrottled(mqttService, 'arm1_1', topic, payload);
                    },
                  ),
                ),
                Expanded(
                  child: CompactVerticalSlider(
                    label: "Motor 2",
                    controlId: 'arm1_2',
                    value: _arm1SliderVal2,
                    accentColor: accentColors[1],
                    onChanged: (v) {
                      setState(() => _arm1SliderVal2 = v);
                      final topic = "servo/2";
                      final payload = jsonEncode({"id": 2, "angle": v.toInt()});
                      _publishThrottled(mqttService, 'arm1_2', topic, payload);
                    },
                  ),
                ),
                Expanded(
                  child: CompactVerticalSlider(
                    label: "Motor 3",
                    controlId: 'arm1_3',
                    value: _arm1SliderVal3,
                    accentColor: accentColors[2],
                    onChanged: (v) {
                      setState(() => _arm1SliderVal3 = v);
                      final topic = "servo/3";
                      final payload = jsonEncode({"id": 3, "angle": v.toInt()});
                      _publishThrottled(mqttService, 'arm1_3', topic, payload);
                    },
                  ),
                ),
                Expanded(
                  child: CompactVerticalSlider(
                    label: "Motor 4",
                    controlId: 'arm1_4',
                    value: _arm1SliderVal4,
                    accentColor: accentColors[3],
                    onChanged: (v) {
                      setState(() => _arm1SliderVal4 = v);
                      final topic = "servo/4";
                      final payload = jsonEncode({"id": 4, "angle": v.toInt()});
                      _publishThrottled(mqttService, 'arm1_4', topic, payload);
                    },
                  ),
                ),
                Expanded(
                  child: CompactVerticalSlider(
                    label: "Motor 5",
                    controlId: 'arm1_5',
                    value: _arm1SliderVal5,
                    accentColor: accentColors[4],
                    onChanged: (v) {
                      setState(() => _arm1SliderVal5 = v);
                      final topic = "servo/5";
                      final payload = jsonEncode({"id": 5, "angle": v.toInt()});
                      _publishThrottled(mqttService, 'arm1_5', topic, payload);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Arm 2 Controls Card
  Widget _buildArm2Controls(MqttService mqttService) {
    // Helper map for Arm 2 labels and control IDs
    final Map<int, String> arm2Labels = { 1: 'a', 2: 'b', 3: 'c', 4: 'd', 5: 'e', 6: 'f' };
    final Map<int, String> arm2MotorTypes = { 1: 'Servo', 2: 'Servo', 3: 'Servo', 4: 'Stepper', 5: 'Stepper', 6: 'Stepper' };
    final List<Color> accentColors = [
      const Color(0xFF0078D4), // Microsoft Blue
      const Color(0xFF107C10), // Microsoft Green
      const Color(0xFF5C2D91), // Microsoft Purple
      const Color(0xFFD83B01), // Microsoft Orange
      const Color(0xFF00B7C3), // Microsoft Teal
      const Color(0xFFFFB900), // Microsoft Yellow
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(6, (index) {
          int motorIndex = index + 1; // 1 to 6
          String label = arm2Labels[motorIndex]!;
          String motorTypeLabel = "${arm2MotorTypes[motorIndex]} ${label.toUpperCase()}"; // e.g., "Servo A"
          String controlId = 'arm2_$label';
          double currentValue;
          
          // Assign correct state variable based on index
          switch (motorIndex) {
            case 1: currentValue = _arm2SliderVal1; break;
            case 2: currentValue = _arm2SliderVal2; break;
            case 3: currentValue = _arm2SliderVal3; break;
            case 4: currentValue = _arm2SliderVal4; break;
            case 5: currentValue = _arm2SliderVal5; break;
            case 6: currentValue = _arm2SliderVal6; break;
            default: currentValue = 90; // Should not happen
          }

          return Expanded(
            child: CompactVerticalSlider(
              label: motorTypeLabel,
              controlId: controlId,
              value: currentValue,
              accentColor: accentColors[index],
              showPresets: index < 3, // Only show presets for first 3 sliders to save space
              onChanged: (v) {
                // Update the correct state variable
                setState(() {
                  switch (motorIndex) {
                    case 1: _arm2SliderVal1 = v; break;
                    case 2: _arm2SliderVal2 = v; break;
                    case 3: _arm2SliderVal3 = v; break;
                    case 4: _arm2SliderVal4 = v; break;
                    case 5: _arm2SliderVal5 = v; break;
                    case 6: _arm2SliderVal6 = v; break;
                  }
                });
                // Publish Arm 2 message
                final topic = "servo/arm2/$label";
                final payload = jsonEncode({"angle": v.toInt()});
                _publishThrottled(mqttService, controlId, topic, payload);
              },
            ),
          );
        }),
      ),
    );
  }

  // --- Main Build Method (Layout adjustments incorporated) ---
  @override
  Widget build(BuildContext context) {
    final mqttService = ref.watch(mqttServiceProvider);
    final connectionState = mqttService.connectionState;
    String connectionStatus; 
    Color statusColor;
    IconData statusIcon;
    
    switch (connectionState) {
      case MqttConnectionState.connected:
        connectionStatus = "Connected";
        statusColor = const Color(0xFF107C10);
        statusIcon = Icons.wifi;
        break;
      case MqttConnectionState.connecting:
        connectionStatus = "Connecting...";
        statusColor = const Color(0xFFFFB900);
        statusIcon = Icons.wifi_find;
        break;
      case MqttConnectionState.disconnected:
        connectionStatus = "Disconnected";
        statusColor = const Color(0xFFD83B01);
        statusIcon = Icons.wifi_off;
        break;
      case MqttConnectionState.disconnecting:
        connectionStatus = "Disconnecting...";
        statusColor = const Color(0xFFFF9800);
        statusIcon = Icons.wifi_off;
        break;
      case MqttConnectionState.faulted:
        connectionStatus = "Connection Error";
        statusColor = const Color(0xFFD13438);
        statusIcon = Icons.error_outline;
        break;
      default:
        connectionStatus = "Unknown";
        statusColor = Colors.grey;
        statusIcon = Icons.question_mark;
    }

    Widget liveKitContentArea;
    if (_isFetchingToken) {
      liveKitContentArea = const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF0078D4),
          strokeWidth: 3,
        ),
      );
    } else if (_tokenError != null) {
      liveKitContentArea = Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, color: Colors.red[700], size: 40),
              const SizedBox(height: 12),
              Text(
                _tokenError!,
                style: TextStyle(color: Colors.red[700], fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text("Retry"),
                onPressed: _fetchAndSetLiveKitToken,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0078D4),
                  foregroundColor: Colors.white,
                  elevation: 2,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (_fetchedLivekitToken == null) {
      liveKitContentArea = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.vpn_key_off_outlined, color: Colors.orange[700], size: 40),
            const SizedBox(height: 12),
            Text(
              "LiveKit token needed",
              style: TextStyle(color: Colors.orange[700], fontSize: 16),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.vpn_key),
              label: const Text("Get Token"),
              onPressed: _fetchAndSetLiveKitToken,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0078D4),
                foregroundColor: Colors.white,
                elevation: 2,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      liveKitContentArea = LiveKitReceiverWidget(
        key: _receiverKey,
        url: livekitUrl,
        token: _fetchedLivekitToken!,
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0078D4),
        elevation: 0,
        title: const Text(
          "Dual Arm Controller",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isVideoExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            tooltip: _isVideoExpanded ? "Exit Fullscreen" : "Fullscreen",
            onPressed: () {
              setState(() {
                _isVideoExpanded = !_isVideoExpanded;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.vpn_key_sharp, color: Colors.white),
            tooltip: "Refresh LiveKit Token",
            onPressed: _fetchAndSetLiveKitToken,
          ),
          IconButton(
            icon: const Icon(Icons.settings_input_component, color: Colors.white),
            tooltip: "Edit LiveKit URL",
            onPressed: _editStreamingSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // --- Top: LiveKit Video Stream Area ---
          Expanded(
            flex: _isVideoExpanded ? 8 : 5, // More space for video when expanded
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    spreadRadius: 0,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: liveKitContentArea,
                  ),
                  // Expand/collapse button overlay
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: FloatingActionButton.small(
                      backgroundColor: Colors.black.withOpacity(0.5),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      onPressed: () {
                        setState(() {
                          _isVideoExpanded = !_isVideoExpanded;
                        });
                      },
                      child: Icon(
                        _isVideoExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          if (!_isVideoExpanded) ...[
            // --- Middle: MQTT Status Bar ---
            Container(
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        statusIcon,
                        size: 16,
                        color: statusColor,
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        connectionStatus,
                        style: TextStyle(
                          fontSize: 14,
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.sync,
                      size: 18,
                      color: (connectionState == MqttConnectionState.connecting ||
                              connectionState == MqttConnectionState.disconnecting)
                          ? Colors.grey
                          : const Color(0xFF0078D4),
                    ),
                    tooltip: "Reconnect MQTT",
                    onPressed: (connectionState == MqttConnectionState.connecting ||
                            connectionState == MqttConnectionState.disconnecting)
                        ? null
                        : () {
                            print("Manual MQTT reconnect requested.");
                            mqttService.disconnect();
                            Future.delayed(const Duration(milliseconds: 300), () {
                              if (mounted) {
                                mqttService.connect();
                              }
                            });
                          },
                  ),
                ],
              ),
            ),
            
            // --- Tab Bar for Arm Selection ---
            Container(
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: const Color(0xFF0078D4),
                  borderRadius: BorderRadius.circular(8),
                ),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.black87,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                tabs: const [
                  Tab(
                    text: "Arm 1",
                    icon: Icon(Icons.architecture, size: 18),
                    height: 50,
                  ),
                  Tab(
                    text: "Arm 2",
                    icon: Icon(Icons.precision_manufacturing, size: 18),
                    height: 50,
                  ),
                ],
              ),
            ),
            
            // --- Bottom: Controls Area ---
            Expanded(
              flex: 5,
              child: Container(
                margin: const EdgeInsets.all(8),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.05, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _selectedArm == 1
                      ? _buildArm1Controls(mqttService)
                      : _buildArm2Controls(mqttService),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ui/motor_control_page.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode/Decode
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk; // Use prefix
import 'package:mqtt_client/mqtt_client.dart' show MqttConnectionState;
import 'package:http/http.dart' as http; // For fetching token

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
  // LiveKit settings
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  Key _receiverKey = UniqueKey();

  // Token Management State
  String? _fetchedLivekitToken;
  bool _isFetchingToken = false;
  String? _tokenError;

  // UI State
  int _selectedArm = 1;
  final List<bool> _isSelected = [true, false];

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
     await showDialog( /* ... (Dialog code remains the same) ... */
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
                    print("LiveKit URL updated.");
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

  // --- UI Builder Widgets ---

  // Vertical Slider (modified for onChanged)
  Widget _buildVerticalSlider({
    required String label,
    required String controlId, // Unique ID for throttling map
    required double value,
    required ValueChanged<double> onChanged, // Takes the current value
    // onChangeEnd is no longer used for publishing
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Column( mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center,),
          const SizedBox(height: 8),
          SizedBox( height: 180, child: RotatedBox( quarterTurns: -1, child: Slider(
                value: value, min: 0, max: 180, divisions: 180,
                label: "${value.toInt()}°",
                onChanged: onChanged, // Use onChanged for immediate UI update and throttled publish
                // onChangeEnd: null, // Remove or leave empty
            ),),),
          const SizedBox(height: 4),
          Text("${value.toInt()}°", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),),
        ],
      ),
    );
  }

  // Arm 1 Controls Card (Updated MQTT logic)
  Widget _buildArm1Controls(MqttService mqttService) {
     return Card( margin: const EdgeInsets.only(top: 8), child: Padding( padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0), child: Column( children: [
       Padding( padding: const EdgeInsets.symmetric(horizontal: 8.0), child: Row( mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.center, children: [
         const Text("Arm 1 Control", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
         Row( mainAxisSize: MainAxisSize.min, children: [
           const Text("Electromagnet:", style: TextStyle(fontSize: 14)), const SizedBox(width: 4),
           Switch( value: _isElectromagnetOn, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
             onChanged: (bool v) {
               setState(() => _isElectromagnetOn = v);
               // *** Publish Electromagnet state directly ***
               final topic = "servo/magnet"; // Use specific sub-topic
               final payload = v ? "ON" : "OFF";
               mqttService.publish(topic, payload);
               _lastSendTime['arm1_magnet'] = DateTime.now(); // Update time for potential throttling (though maybe not needed for switch)
             },
           ),
         ],),],),),
       const Divider(height: 15, thickness: 1),
       Expanded( child: SingleChildScrollView( scrollDirection: Axis.horizontal, child: Row( mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.center, children: [
         // --- Servo 1 ---
         _buildVerticalSlider(
            label: "Motor 1", controlId: 'arm1_1', value: _arm1SliderVal1,
            onChanged: (v) {
              setState(() => _arm1SliderVal1 = v); // Update UI first
              final topic = "servo/1"; // Original topic
              final payload = jsonEncode({"id": 1, "angle": v.toInt()}); // Original payload
              _publishThrottled(mqttService, 'arm1_1', topic, payload); // Use throttled publish
            },
         ),
         // --- Servo 2 ---
         _buildVerticalSlider(
            label: "Motor 2", controlId: 'arm1_2', value: _arm1SliderVal2,
            onChanged: (v) {
              setState(() => _arm1SliderVal2 = v);
              final topic = "servo/2";
              final payload = jsonEncode({"id": 2, "angle": v.toInt()});
              _publishThrottled(mqttService, 'arm1_2', topic, payload);
            },
         ),
         // --- Servo 3 ---
          _buildVerticalSlider(
            label: "Motor 3", controlId: 'arm1_3', value: _arm1SliderVal3,
            onChanged: (v) {
              setState(() => _arm1SliderVal3 = v);
              final topic = "servo/3";
              final payload = jsonEncode({"id": 3, "angle": v.toInt()});
              _publishThrottled(mqttService, 'arm1_3', topic, payload);
            },
         ),
         // --- Servo 4 ---
          _buildVerticalSlider(
            label: "Motor 4", controlId: 'arm1_4', value: _arm1SliderVal4,
            onChanged: (v) {
              setState(() => _arm1SliderVal4 = v);
              final topic = "servo/4";
              final payload = jsonEncode({"id": 4, "angle": v.toInt()});
              _publishThrottled(mqttService, 'arm1_4', topic, payload);
            },
         ),
         // --- Servo 5 ---
          _buildVerticalSlider(
            label: "Motor 5", controlId: 'arm1_5', value: _arm1SliderVal5,
            onChanged: (v) {
              setState(() => _arm1SliderVal5 = v);
              final topic = "servo/5";
              final payload = jsonEncode({"id": 5, "angle": v.toInt()});
              _publishThrottled(mqttService, 'arm1_5', topic, payload);
            },
         ),
       ],),),),],),),);
  }

  // Arm 2 Controls Card (Updated MQTT logic)
  Widget _buildArm2Controls(MqttService mqttService) {
     // Helper map for Arm 2 labels and control IDs
     final Map<int, String> arm2Labels = { 1: 'a', 2: 'b', 3: 'c', 4: 'd', 5: 'e', 6: 'f' };
     final Map<int, String> arm2MotorTypes = { 1: 'Servo', 2: 'Servo', 3: 'Servo', 4: 'Stepper', 5: 'Stepper', 6: 'Stepper' };

     return Card( margin: const EdgeInsets.only(top: 8), child: Padding( padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0), child: Column( children: [
       const Padding( padding: EdgeInsets.symmetric(horizontal: 8.0), child: Align( alignment: Alignment.centerLeft, child: Text("Arm 2 Control", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),),
       const Divider(height: 15, thickness: 1),
       Expanded( child: SingleChildScrollView( scrollDirection: Axis.horizontal, child: Row( mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.center,
         children: List.generate(6, (index) { // Generate 6 sliders
            int motorIndex = index + 1; // 1 to 6
            String label = arm2Labels[motorIndex]!;
            String motorTypeLabel = "${arm2MotorTypes[motorIndex]} ${label.toUpperCase()}"; // e.g., "Servo A"
            String controlId = 'arm2_$label';
            double currentValue;
            // Assign correct state variable based on index
            switch (motorIndex) {
              case 1: currentValue = _arm2SliderVal1; break; case 2: currentValue = _arm2SliderVal2; break;
              case 3: currentValue = _arm2SliderVal3; break; case 4: currentValue = _arm2SliderVal4; break;
              case 5: currentValue = _arm2SliderVal5; break; case 6: currentValue = _arm2SliderVal6; break;
              default: currentValue = 90; // Should not happen
            }

            return _buildVerticalSlider(
              label: motorTypeLabel, // Use descriptive label
              controlId: controlId,
              value: currentValue,
              onChanged: (v) {
                // Update the correct state variable
                setState(() {
                  switch (motorIndex) {
                    case 1: _arm2SliderVal1 = v; break; case 2: _arm2SliderVal2 = v; break;
                    case 3: _arm2SliderVal3 = v; break; case 4: _arm2SliderVal4 = v; break;
                    case 5: _arm2SliderVal5 = v; break; case 6: _arm2SliderVal6 = v; break;
                  }
                });
                // *** Publish Arm 2 message ***
                final topic = "servo/arm2/$label"; // New topic format
                final payload = jsonEncode({"angle": v.toInt()}); // Simple payload
                _publishThrottled(mqttService, controlId, topic, payload); // Use throttled publish
              },
            );
          }),
       ),),),],),),);
  }

  // --- Main Build Method (Layout adjustments incorporated) ---
  @override
  Widget build(BuildContext context) {
    final mqttService = ref.watch(mqttServiceProvider);
    final connectionState = mqttService.connectionState;
    String connectionStatus; Color statusColor;
    switch (connectionState) { /* ... status logic ... */
      case MqttConnectionState.connected: connectionStatus = "Connected"; statusColor = Colors.green.shade600; break;
      case MqttConnectionState.connecting: connectionStatus = "Connecting..."; statusColor = Colors.orange.shade600; break;
      case MqttConnectionState.disconnected: connectionStatus = "Disconnected"; statusColor = Colors.red.shade600; break;
      case MqttConnectionState.disconnecting: connectionStatus = "Disconnecting..."; statusColor = Colors.orange.shade400; break;
      case MqttConnectionState.faulted: connectionStatus = "Faulted"; statusColor = Colors.red.shade800; break;
      default: connectionStatus = "Unknown"; statusColor = Colors.grey.shade500;
    }

     Widget liveKitContentArea;
     if (_isFetchingToken) { liveKitContentArea = const Center(child: CircularProgressIndicator()); }
     else if (_tokenError != null) { liveKitContentArea = Center( child: Padding( padding: const EdgeInsets.all(16.0), child: Column( mainAxisSize: MainAxisSize.min, children: [ Icon(Icons.cloud_off, color: Colors.red[300], size: 30), SizedBox(height: 8), Text(_tokenError!, style: TextStyle(color: Colors.red[300])), SizedBox(height: 10), ElevatedButton.icon( icon: const Icon(Icons.refresh), label: const Text("Retry Fetch"), onPressed: _fetchAndSetLiveKitToken, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey)) ],),),); }
     else if (_fetchedLivekitToken == null) { liveKitContentArea = Center( child: Column( mainAxisSize: MainAxisSize.min, children: [ Icon(Icons.vpn_key_off_outlined, color: Colors.orange[300], size: 30), SizedBox(height: 8), Text("LiveKit token needed.", style: TextStyle(color: Colors.orange[300])), SizedBox(height: 10), ElevatedButton.icon( icon: const Icon(Icons.vpn_key), label: const Text("Get Token"), onPressed: _fetchAndSetLiveKitToken, style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey)) ],),); }
     else { liveKitContentArea = LiveKitReceiverWidget( key: _receiverKey, url: livekitUrl, token: _fetchedLivekitToken!,); }


    return Scaffold(
      appBar: AppBar(
         title: const Text("Dual Arm Controller"),
         actions: [ IconButton(icon: const Icon(Icons.vpn_key_sharp), tooltip: "Refresh LiveKit Token", onPressed: _fetchAndSetLiveKitToken,), IconButton( icon: const Icon(Icons.settings_input_component), tooltip: "Edit LiveKit URL", onPressed: _editStreamingSettings,),],
      ),
      body: Column( children: [
          // --- Top: LiveKit Video Stream Area ---
          Expanded( flex: 4, child: Container( width: double.infinity, color: Colors.black, child: liveKitContentArea,),),
          // --- Middle: MQTT Status Bar ---
          Container( height: 55, color: Theme.of(context).cardTheme.color ?? Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16.0), child: Row( mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ Row(children: [ Icon(Icons.rss_feed, size: 20, color: statusColor), SizedBox(width: 8), Container( width: 10, height: 10, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),), SizedBox(width: 8), Text(connectionStatus, style: TextStyle(fontSize: 15, color: statusColor, fontWeight: FontWeight.w500)),],), IconButton( icon: const Icon(Icons.sync_problem_outlined), tooltip: "Reconnect MQTT", color: Theme.of(context).primaryColor, iconSize: 24, onPressed: (connectionState == MqttConnectionState.connecting || connectionState == MqttConnectionState.disconnecting) ? null : () { print("Manual MQTT reconnect requested."); mqttService.disconnect(); Future.delayed(const Duration(milliseconds: 300), () { if (mounted) { mqttService.connect(); } }); },), ],),),
          // --- Bottom: Controls Area ---
          Expanded( flex: 6, child: Container( color: Colors.grey[200], padding: const EdgeInsets.fromLTRB(8.0, 0, 8.0, 8.0), child: Column( crossAxisAlignment: CrossAxisAlignment.stretch, children: [
             Padding( padding: const EdgeInsets.symmetric(vertical: 8.0), child: Center( child: ToggleButtons( isSelected: _isSelected, onPressed: (int index) { if (_isSelected[index]) return; setState(() { _selectedArm = index + 1; for (int i = 0; i < _isSelected.length; i++) { _isSelected[i] = (i == index); } }); }, constraints: const BoxConstraints(minHeight: 38.0, minWidth: 120.0), children: const <Widget>[ Text('Arm 1 Control'), Text('Arm 2 Control'), ],),),),
             Expanded( child: AnimatedSwitcher( duration: const Duration(milliseconds: 200), transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child), child: _selectedArm == 1 ? Container(key: const ValueKey('arm1_controls'), child: _buildArm1Controls(mqttService)) : Container(key: const ValueKey('arm2_controls'), child: _buildArm2Controls(mqttService)),),),],),),),
        ],
      ),
    );
  }
}
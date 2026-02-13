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
  String livekitUrl = 'wss://test-wfkuoo8g.livekit.cloud';
  Key _receiverKey = UniqueKey();
  String? _fetchedLivekitToken;
  bool _isFetchingToken = false;
  String? _tokenError;
  int _selectedControlTabIndex = 0;
  final List<bool> _isSelected = [true, false];
  static const double _initialMotorA = 90.0, _initialMotorC = 90.0, _initialMotorE = 50.0;
  static const double _initialMotorH_Open = 100.0, _initialMotorH_Closed = 0.0;
  double _motorA_angle = _initialMotorA;
  double _motorC_angle = _initialMotorC;
  double _motorE_angle = _initialMotorE;
  double _motorH_angle = _initialMotorH_Open;
  Timer? _motorUpdateTimer;
  double _arm2SliderVal1 = 90; double _arm2SliderVal2 = 90; double _arm2SliderVal3 = 90;
  double _arm2SliderVal4 = 90; double _arm2SliderVal5 = 90; double _arm2SliderVal6 = 90;
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

  // MODIFIED: Expanded reset functionality
  void _resetGamepadToDefaults(MqttService mqttService) {
    setState(() {
      // Reset gamepad-controlled motors
      _motorA_angle = _initialMotorA;
      _motorC_angle = _initialMotorC;
      _motorE_angle = _initialMotorE;
      _motorH_angle = _initialMotorH_Open;
      // Also reset slider-controlled motors for consistency
      _arm2SliderVal2 = 90.0; // B
      _arm2SliderVal4 = 90.0; // D
      _arm2SliderVal6 = 90.0; // F
    });
    // Publish reset values for ALL motors
    mqttService.publish("servo/arm2/a", jsonEncode({"angle": _motorA_angle.toInt()}));
    mqttService.publish("servo/arm2/c", jsonEncode({"angle": _motorC_angle.toInt()}));
    mqttService.publish("servo/arm2/e", jsonEncode({"angle": _motorE_angle.toInt()}));
    mqttService.publish("servo/arm2/h", jsonEncode({"angle": _motorH_angle.toInt()}));
    // Also publish resets for b, d, f
    mqttService.publish("servo/arm2/b", jsonEncode({"angle": 90}));
    mqttService.publish("servo/arm2/d", jsonEncode({"angle": 90}));
    mqttService.publish("servo/arm2/f", jsonEncode({"angle": 90}));
    print("All arm 2 motors have been reset to default values.");
  }

  // MODIFIED: Smaller button size for compact layout
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
          padding: const EdgeInsets.all(8.0), // Reduced padding
          child: Icon(icon, size: 28.0, color: Theme.of(context).primaryColor), // Reduced icon size
        ),
      ),
    );
  }

  // MODIFIED: Complete overhaul for compact layout on narrow screens
  Widget _buildGamepadControls(MqttService mqttService) {
    bool isClawOpen = _motorH_angle == _initialMotorH_Open;

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        // Reduced padding to maximize space
        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // --- Left Column: Directional Pad (Motors c & a) ---
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildContinuousControlButton(
                    icon: Icons.arrow_upward,
                    onUpdate: () {
                      setState(() => _motorC_angle = (_motorC_angle + 1.0).clamp(20.0, 100.0));
                      _publishThrottled(mqttService, 'arm2_c', 'servo/arm2/c', jsonEncode({"angle": _motorC_angle.toInt()}));
                    },
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildContinuousControlButton(
                        icon: Icons.arrow_back,
                        onUpdate: () {
                          setState(() => _motorA_angle = (_motorA_angle - 1.0).clamp(35.0, 125.0));
                          _publishThrottled(mqttService, 'arm2_a', 'servo/arm2/a', jsonEncode({"angle": _motorA_angle.toInt()}));
                        },
                      ),
                      const SizedBox(width: 48), // Reduced spacer
                      _buildContinuousControlButton(
                        icon: Icons.arrow_forward,
                        onUpdate: () {
                          setState(() => _motorA_angle = (_motorA_angle + 1.0).clamp(35.0, 125.0));
                          _publishThrottled(mqttService, 'arm2_a', 'servo/arm2/a', jsonEncode({"angle": _motorA_angle.toInt()}));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _buildContinuousControlButton(
                    icon: Icons.arrow_downward,
                    onUpdate: () {
                      setState(() => _motorC_angle = (_motorC_angle - 1.0).clamp(20.0, 100.0));
                      _publishThrottled(mqttService, 'arm2_c', 'servo/arm2/c', jsonEncode({"angle": _motorC_angle.toInt()}));
                    },
                  ),
                ],
              ),
            ),
            // --- Center Column: Claw Control (Motor h) ---
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Claw", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    style: (isClawOpen ? ElevatedButton.styleFrom(minimumSize: const Size(80, 40)) : OutlinedButton.styleFrom(minimumSize: const Size(80, 40))),
                    onPressed: () {
                      setState(() => _motorH_angle = _initialMotorH_Open);
                      mqttService.publish('servo/arm2/h', jsonEncode({"angle": _initialMotorH_Open.toInt()}));
                    },
                    child: const Text("Open"),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: (!isClawOpen ? ElevatedButton.styleFrom(minimumSize: const Size(80, 40)) : OutlinedButton.styleFrom(minimumSize: const Size(80, 40))),
                    onPressed: () {
                      setState(() => _motorH_angle = _initialMotorH_Closed);
                      mqttService.publish('servo/arm2/h', jsonEncode({"angle": _initialMotorH_Closed.toInt()}));
                    },
                    child: const Text("Close"),
                  ),
                ],
              ),
            ),
            // --- Right Column: Forward/Back Control (Motor e) ---
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Forward", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 4),
                  _buildContinuousControlButton(
                    icon: Icons.arrow_upward,
                    // MODIFIED: Direction and speed
                    onUpdate: () {
                      setState(() => _motorE_angle = (_motorE_angle - 2.0).clamp(45.0, 160.0));
                      _publishThrottled(mqttService, 'arm2_e', 'servo/arm2/e', jsonEncode({"angle": _motorE_angle.toInt()}));
                    },
                  ),
                  const SizedBox(height: 32), // Reduced spacer
                  _buildContinuousControlButton(
                    icon: Icons.arrow_downward,
                    // MODIFIED: Direction and speed
                    onUpdate: () {
                      setState(() => _motorE_angle = (_motorE_angle + 2.0).clamp(45.0, 160.0));
                      _publishThrottled(mqttService, 'arm2_e', 'servo/arm2/e', jsonEncode({"angle": _motorE_angle.toInt()}));
                    },
                  ),
                  const SizedBox(height: 4),
                  const Text("Back", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                    setState(() => _motorH_angle = 110);
                    mqttService.publish('servo/arm2/h', jsonEncode({"angle": 110}));
                  },
                  child: const Text("Open"),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _motorH_angle = 0);
                    mqttService.publish('servo/arm2/h', jsonEncode({"angle": 0}));
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
                        case 1: currentValue = _arm2SliderVal1; break; case 2: currentValue = _arm2SliderVal2; break;
                        case 3: currentValue = _arm2SliderVal3; break; case 4: currentValue = _arm2SliderVal4; break;
                        case 5: currentValue = _arm2SliderVal5; break; case 6: currentValue = _arm2SliderVal6; break;
                        default: currentValue = 90;
                      }

                      return _buildVerticalSlider(
                        label: motorTypeLabel, controlId: controlId, value: currentValue,
                        onChanged: (v) {
                          setState(() {
                            switch (motorIndex) {
                              case 1: _arm2SliderVal1 = v; break; case 2: _arm2SliderVal2 = v; break;
                              case 3: _arm2SliderVal3 = v; break; case 4: _arm2SliderVal4 = v; break;
                              case 5: _arm2SliderVal5 = v; break; case 6: _arm2SliderVal6 = v; break;
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
             // MODIFIED: Reset button moved here
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
                  // This is the new Reset button
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
// providers/arm_controller_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/mqtt_service.dart'; // Ensure path is correct

// Define only the MQTT service provider
final mqttServiceProvider = Provider<MqttService>((ref) {
  // Create unique client ID to avoid conflicts if multiple instances run
  final clientId = 'flutter_dual_arm_app_${DateTime.now().millisecondsSinceEpoch}_${Uri.base.host}';

  final service = MqttService(
    broker: '178.128.54.195', // Your MQTT Broker IP/Domain
    port: 1883,             // Standard TCP Port (for non-web)
    websocketPort: 9001,    // <<< !!! YOUR MQTT BROKER's WEBSOCKET PORT !!! >>>
                            // Common ports: 9001 (WSS), 8083/8080 (WS)
                            // Make absolutely sure this matches your broker config!
    clientId: clientId,
    // Add username/password if required by your broker:
    // username: 'your_username',
    // password: 'your_password',
  );

  // Initial connection attempt (optional, can be triggered by UI instead)
  // service.connect();

  // Ensure disconnection when the provider is disposed
  ref.onDispose(() {
     print("Disposing MQTT Service Provider, disconnecting client...");
     service.disconnect();
  });
  return service;
});
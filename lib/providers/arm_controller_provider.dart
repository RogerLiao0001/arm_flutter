// providers/arm_controller_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/mqtt_service.dart'; // Ensure path is correct

final mqttServiceProvider = Provider<MqttService>((ref) {
  // Use a unique client ID for each session/instance
  final clientId = 'flutter_webapp_${DateTime.now().millisecondsSinceEpoch}';

  final service = MqttService(
    broker: 'roger01.site',    // Domain name for both Web and Native
    // port: 1883,             // <<<--- REMOVE this line ---<<<
    clientId: clientId,
    // Add username/password if needed
    // username: 'your_username',
    // password: 'your_password',
  );

  ref.onDispose(() {
     print("Disposing MQTT Service Provider, disconnecting client...");
     service.disconnect();
  });
  return service;
});
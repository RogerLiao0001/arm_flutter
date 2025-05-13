// lib/services/mqtt_service.dart

import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttService {
  final String broker; // e.g., "roger01.site"
  final String clientId;
  final String? username;
  final String? password;

  MqttClient? _client;
  Function(String topic, String payload)? _messageCallback;

  MqttService({
    required this.broker,
    required this.clientId,
    this.username,
    this.password,
    // Removed port from constructor entirely
  });

  MqttConnectionState? get connectionState =>
      _client?.connectionStatus?.state;

  void setOnMessageReceivedCallback(
      Function(String topic, String payload) callback) {
    _messageCallback = callback;
  }

  Future<void> connect() async {
    if (_client != null &&
        (_client!.connectionStatus?.state == MqttConnectionState.connected ||
         _client!.connectionStatus?.state == MqttConnectionState.connecting)) {
      print('MQTT: Already connecting or connected, skipping.');
      return;
    }

    _client?.disconnect();
    _client = null;

    const int standardTcpPort = 1883; // Only used for Native

    try {
      if (kIsWeb) {
        String wsProtocol = 'wss';
        // URL without port, path handled by Nginx
        final wsUrl = '$wsProtocol://$broker/mqtt';
        print('MQTT(Web): initializing client for $wsUrl');

        // Create the client instance FIRST
        _client = MqttBrowserClient(wsUrl, clientId, maxConnectionAttempts: 3);

        // --- *** THE CRITICAL FIX: Explicitly set port AFTER creation *** ---
        // Even though URL implies 443, set it explicitly to override any potential
        // incorrect internal defaulting or picking up the stray '1883' constant.
        (_client as MqttBrowserClient).port = 443;
        print('MQTT(Web): Explicitly setting WebSocket port to 443.');
        // --- *** End of Critical Fix *** ---

        // Set protocols (usually needed for browser clients)
        (_client as MqttBrowserClient).websocketProtocols = MqttClientConstants.protocolsSingleDefault;
        // Secure flag is usually inferred from 'wss', but can be set if needed:
        // (_client as MqttBrowserClient).secure = true;

      } else {
        // Native uses TCP with the standard port
        print('MQTT(Native): initializing server client for $broker:$standardTcpPort');
        _client = MqttServerClient.withPort(broker, clientId, standardTcpPort, maxConnectionAttempts: 3);
        // No need to set .port again here, constructor handles it.
      }

      // Common client setup (logging, keepalive, callbacks etc.)
      _client!
        ..logging(on: kDebugMode)
        ..keepAlivePeriod = 30
        ..autoReconnect = true
        ..resubscribeOnAutoReconnect = true
        ..onDisconnected = _onDisconnected
        ..onConnected = _onConnected
        ..onSubscribed = _onSubscribed
        ..pongCallback = _onPong;

      // Connection Message
      final connMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);
      if (username != null && password != null) {
        connMessage.authenticateAs(username!, password!);
      }
      _client!.connectionMessage = connMessage;

      // Attempt connection
      print('MQTT: Attempting connection (Port explicitly set to ${_client?.port})...');
      await _client!.connect(username, password);

      if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
        print('MQTT: Connected successfully!');
        _setupListeners();
      } else {
        print('MQTT: Connection attempt finished, but final state is not connected: ${_client!.connectionStatus?.state}');
        _client?.disconnect(); _client = null;
      }

    } catch (e) {
      print('MQTT: Connection setup exception: $e');
      _client?.disconnect(); _client = null;
    }
  }

  void _setupListeners() { /* ... Keep existing ... */
     _client?.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
      if (c != null && c.isNotEmpty) {
        final MqttMessage? message = c[0].payload;
        if (message is MqttPublishMessage) {
           final MqttPublishMessage recMess = message;
           final String topic = c[0].topic;
           final String payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
           _messageCallback?.call(topic, payload);
        }
      }
    }).onError((error) {
      print('MQTT: Updates listener error: $error');
    });
    print('MQTT: Updates listener active.');
  }

  // --- Other methods (subscribe, publish, disconnect, callbacks) ---
  // Keep the existing implementations
  void subscribe(String topic, {MqttQos qos = MqttQos.atLeastOnce}) { /* ... Keep existing ... */
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        print('MQTT: Subscribing to $topic');
        _client!.subscribe(topic, qos);
    } else {
        print('MQTT: Cannot subscribe to $topic, client not connected.');
    }
  }
  void publish(String topic, String message, {MqttQos qos = MqttQos.atLeastOnce, bool retain = false}) { /* ... Keep existing ... */
     if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        final builder = MqttClientPayloadBuilder();
        builder.addString(message);
        _client!.publishMessage(topic, qos, builder.payload!, retain: retain);
     } else {
        print('MQTT: Cannot publish to $topic, client not connected.');
     }
  }
  void disconnect() { /* ... Keep existing ... */
    print('MQTT: Disconnecting client...');
    _client?.disconnect();
  }
  void _onConnected() => print('MQTT: onConnected callback');
  void _onDisconnected() => print('MQTT: onDisconnected callback, state=${_client?.connectionStatus?.state}');
  void _onSubscribed(String topic) => print('MQTT: onSubscribed callback for $topic');
  void _onPong() => print('MQTT: Received PONG');

} // End of MqttService class
// services/mqtt_service.dart
import 'package:flutter/foundation.dart'; // For kIsWeb check
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart'; // Import browser client

class MqttService {
  final String broker;
  final int port; // Standard MQTT TCP Port (for non-web)
  final String clientId;
  final String? username;
  final String? password;
  // --- WebSocket Port for Web ---
  // !! 根據您的 Mosquitto 設定檔，目前是 9001 !!
  final int websocketPort;

  MqttClient? _client;
  Function(String topic, String payload)? _onMessageReceivedCallback;

  MqttConnectionState? get connectionState => _client?.connectionStatus?.state;

  MqttService({
    required this.broker,
    required this.port, // e.g., 1883
    required this.clientId,
    this.username,
    this.password,
    // 確保這裡的 Port 和您在 Mosquitto 設定的 listener 一致
    this.websocketPort = 9001, // <--- 預設為 9001，因為這是您設定的
  });

  Future<void> connect() async {
    if (_client != null &&
        (_client?.connectionStatus?.state == MqttConnectionState.connecting ||
         _client?.connectionStatus?.state == MqttConnectionState.connected)) {
      print('MQTT: Already connected or connecting.');
      return;
    }

    _client?.disconnect(); // Disconnect previous instance if any

    if (kIsWeb) {
      // --- *** 關鍵修改：強制 ws:// for Port 9001 *** ---
      String wsProtocol;
      // 因為您的 Mosquitto 在 9001 上設定的是未加密的 websockets (沒有 SSL/TLS)
      // 所以這裡必須使用 'ws'
      if (websocketPort == 9001) { // <--- 直接判斷您設定的 Port
         wsProtocol = 'ws';
         print("MQTT (Web): Forcing INSECURE WebSocket (ws://) for port $websocketPort based on configuration.");
      } else if (websocketPort == 443 || websocketPort == 8883 || websocketPort == 8084) { // 判斷常見的 WSS Port
         wsProtocol = 'wss';
         print("MQTT (Web): Using secure WebSocket (wss://) for standard SSL port $websocketPort");
      } else {
         // 對於其他未知 Port，更安全的預設可能是 ws，但需要您確認 Broker 設定
         wsProtocol = 'ws';
         print("MQTT (Web): Assuming insecure WebSocket (ws://) for non-standard port $websocketPort - PLEASE VERIFY BROKER CONFIG");
      }
      // --- *** 修改結束 *** ---

      String wsUrl = '$wsProtocol://$broker';
      _client = MqttBrowserClient.withPort(wsUrl, clientId, websocketPort, maxConnectionAttempts: 3);
      // For MqttBrowserClient, you often don't need to set websocketProtocols explicitly
      // unless facing specific compatibility issues. Let's keep it simple for now.
      // (_client as MqttBrowserClient).websocketProtocols = MqttClientConstants.protocolsSingleDefault;

      print('MQTT (Web): Initializing WebSocket client for $wsUrl:$websocketPort ...');

    } else {
      // Use MqttServerClient for non-Web
      _client = MqttServerClient.withPort(broker, clientId, port, maxConnectionAttempts: 3);
      print('MQTT (Native): Initializing TCP client for $broker:$port ...');
    }

    // Common client setup
    _client!.logging(on: kDebugMode);
    _client!.keepAlivePeriod = 30;
    _client!.autoReconnect = true;
    _client!.resubscribeOnAutoReconnect = true;
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = _onSubscribed;
    _client!.onAutoReconnect = _onAutoReconnect;
    _client!.onAutoReconnected = _onAutoReconnected;
    _client!.pongCallback = _pong;

     final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

     if (username != null && password != null) {
       connMessage.authenticateAs(username!, password!);
     }
     _client!.connectionMessage = connMessage;

    try {
      print('MQTT: Attempting to connect...');
      await _client!.connect(username, password);
    } catch (e) {
      print('MQTT: Connection exception: $e');
      _client?.disconnect();
      _client = null;
      return;
    }

    if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
      print('MQTT: Connection successful!');
      _setupUpdatesListener(); // Setup listener after successful connection
    } else {
      print('MQTT: Connection failed after attempt, final state: ${_client!.connectionStatus?.state}');
      _client?.disconnect();
      _client = null;
    }
  }

  void _setupUpdatesListener() {
    _client?.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
      if (c != null && c.isNotEmpty) {
        final recMess = c[0].payload as MqttPublishMessage;
        final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        _onMessageReceivedCallback?.call(c[0].topic, pt);
      }
    }).onError((error) {
         print('MQTT Updates listener error: $error');
    });
     print("MQTT: Updates listener is active.");
  }

  void setOnMessageReceivedCallback(Function(String topic, String payload) callback) {
     _onMessageReceivedCallback = callback;
  }

  void disconnect() {
    if (_client != null) {
       print("MQTT: Disconnecting client...");
       _client!.disconnect();
    }
  }

  void _onConnected() {
    print('MQTT: Connected callback.');
  }

  void _onDisconnected() {
    print('MQTT: Disconnected callback. State: ${_client?.connectionStatus?.state}');
  }

  void _onAutoReconnect() {
    print('MQTT: Auto Reconnect attempt...');
  }

  void _onAutoReconnected() {
    print('MQTT: Auto Reconnect successful.');
    _setupUpdatesListener(); // Ensure listener is active after reconnect
  }

   void _pong() {
     // Keepalive pong received
   }

  void _onSubscribed(String topic) {
    print('MQTT: Subscribed to $topic');
  }

  void subscribe(String topic, {MqttQos qos = MqttQos.atLeastOnce}) {
     if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        print('MQTT: Subscribing to $topic');
        _client!.subscribe(topic, qos);
     } else {
        print('MQTT: Cannot subscribe to $topic, client not connected.');
     }
  }

  void publish(String topic, String message, {MqttQos qos = MqttQos.atLeastOnce, bool retain = false}) {
     if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        final builder = MqttClientPayloadBuilder();
        builder.addString(message);
        _client!.publishMessage(topic, qos, builder.payload!, retain: retain);
     } else {
        print('MQTT: Cannot publish to $topic, client not connected.');
     }
  }
}
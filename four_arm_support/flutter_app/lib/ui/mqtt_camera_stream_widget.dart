import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttCameraStreamWidget extends StatefulWidget {
  final String mqttBroker;
  final int mqttPort;
  final String topic;
  final BoxFit fit;
  const MqttCameraStreamWidget({
    Key? key,
    required this.mqttBroker,
    required this.mqttPort,
    required this.topic,
    this.fit = BoxFit.contain,
  }) : super(key: key);

  @override
  _MqttCameraStreamWidgetState createState() => _MqttCameraStreamWidgetState();
}

class _MqttCameraStreamWidgetState extends State<MqttCameraStreamWidget> {
  MqttServerClient? _client;
  Uint8List? _imageBytes;
  String _connectionStatus = "Disconnected";

  @override
  void initState() {
    super.initState();
    _setupMqtt();
  }

  Future<void> _setupMqtt() async {
    _client = MqttServerClient(widget.mqttBroker, "FlutterCameraClient");
    _client!.port = widget.mqttPort;
    _client!.logging(on: true);
    _client!.keepAlivePeriod = 20;
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = _onSubscribed;
    final connMess = MqttConnectMessage()
        .withClientIdentifier("FlutterCameraClient")
        .withWillQos(MqttQos.atLeastOnce);
    _client!.connectionMessage = connMess;
    try {
      await _client!.connect();
    } catch (e) {
      print("MQTT camera stream connection error: $e");
      _disconnect();
      return;
    }
    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      setState(() {
        _connectionStatus = "Connected";
      });
      _client!.subscribe(widget.topic, MqttQos.atLeastOnce);
    } else {
      print("MQTT camera stream connection failed, status: ${_client!.connectionStatus!.state}");
      _disconnect();
    }
    _client!.updates!.listen(_onMessage);
  }

  void _onConnected() {
    print("MQTT camera stream connected");
    setState(() {
      _connectionStatus = "Connected";
    });
  }

  void _onDisconnected() {
    print("MQTT camera stream disconnected");
    setState(() {
      _connectionStatus = "Disconnected";
    });
  }

  void _onSubscribed(String topic) {
    print("Subscribed to topic: $topic");
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> event) {
    final recMess = event[0].payload as MqttPublishMessage;
    final payload = recMess.payload.message;
    setState(() {
      _imageBytes = Uint8List.fromList(payload);
    });
  }

  void _disconnect() {
    _client?.disconnect();
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes != null) {
      return Image.memory(_imageBytes!, fit: widget.fit);
    } else {
      return Center(
        child: Text(
          "Waiting for stream...\nStatus: $_connectionStatus",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      );
    }
  }
}

//services/mqtt_service.dart
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttService {
  final String broker;
  final int port;
  final String clientId;
  final String? username;
  final String? password;

  MqttServerClient? _client;

  // 取得目前連線狀態
  MqttConnectionState? get connectionState => _client?.connectionStatus?.state;

  MqttService({
    required this.broker,
    required this.port,
    required this.clientId,
    this.username,
    this.password,
  });

  /// 連線到 MQTT Broker
  Future<void> connect() async {
    _client = MqttServerClient(broker, clientId);
    _client!.port = port;
    _client!.logging(on: true);
    _client!.keepAlivePeriod = 60; // 延長 keepAlivePeriod
    _client!.autoReconnect = true; // 啟用自動重連
    _client!.resubscribeOnAutoReconnect = true; // 重連時自動重新訂閱

    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = _onSubscribed;

    // 設定連線訊息與（若需要）帳密驗證
    if (username != null && password != null) {
      _client!.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .withWillQos(MqttQos.atLeastOnce)
          .authenticateAs(username!, password!);
    } else {
      _client!.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .withWillQos(MqttQos.atLeastOnce);
    }

    try {
      print('MQTT: 開始連線至 $broker:$port ...');
      await _client!.connect();
    } catch (e) {
      print('MQTT: 連線失敗，原因：$e');
      disconnect();
      return;
    }

    if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
      print('MQTT: 連線成功！');
    } else {
      print('MQTT: 連線失敗，狀態: ${_client!.connectionStatus?.state}');
      disconnect();
    }
  }

  /// 中斷連線
  void disconnect() {
    _client?.disconnect();
    _onDisconnected();
  }

  /// 連線成功回呼
  void _onConnected() {
    print('MQTT: onConnected callback invoked.');
  }

  /// 連線中斷回呼
  void _onDisconnected() {
    print('MQTT: 連線中斷');
    _client = null;
  }

  /// _onSubscribed 回呼：當成功訂閱後被呼叫
  void _onSubscribed(String topic) {
    print('MQTT: 已訂閱主題: $topic');
  }

  /// 訂閱指定 Topic
  void subscribe(String topic) {
    if (_client == null) return;
    print('MQTT: 訂閱 => $topic');
    _client!.subscribe(topic, MqttQos.atLeastOnce);
    _client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (var message in messages) {
        final recMess = message.payload as MqttPublishMessage;
        final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        print('MQTT: [${message.topic}] $pt');
      }
    });
  }

  /// 發佈訊息到指定 Topic
  void publish(String topic, String message) {
    if (_client == null) {
      print('MQTT: 無法發佈，尚未連線');
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    print('MQTT: 發佈 => topic: $topic, message: $message');
    _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }
}

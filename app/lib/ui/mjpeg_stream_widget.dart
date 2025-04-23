import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

class VideoStreamWidget extends StatefulWidget {
  final String janusApiUrl;
  final int streamId;

  const VideoStreamWidget({
    Key? key,
    required this.janusApiUrl,
    required this.streamId,
  }) : super(key: key);

  @override
  _VideoStreamWidgetState createState() => _VideoStreamWidgetState();
}

class _VideoStreamWidgetState extends State<VideoStreamWidget> {
  late RTCPeerConnection _peerConnection;
  final _remoteRenderer = RTCVideoRenderer();
  int? _sessionId;
  String? _handleId;

  @override
  void initState() {
    super.initState();
    _initRenderer();
    _initJanusConnection();
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

  Future<void> _initJanusConnection() async {
    await _createSession();
    await _attachPlugin();
    await _watchStream();
  }

  Future<void> _createSession() async {
    final response = await http.post(
      Uri.parse(widget.janusApiUrl),
      body: jsonEncode({"janus": "create", "transaction": "txn1"}),
    );

    final data = jsonDecode(response.body);
    _sessionId = data['data']['id'];
    debugPrint("Session ID: $_sessionId");
  }

  Future<void> _attachPlugin() async {
    final response = await http.post(
      Uri.parse("${widget.janusApiUrl}/$_sessionId"),
      body: jsonEncode({
        "janus": "attach",
        "plugin": "janus.plugin.streaming",
        "transaction": "txn2",
      }),
    );

    final data = jsonDecode(response.body);
    _handleId = data['data']['id'].toString();
    debugPrint("Handle ID: $_handleId");
  }

  Future<void> _watchStream() async {
    _peerConnection = await createPeerConnection(
      {"iceServers": []},
      {'mandatory': {}, 'optional': []},
    );

    _peerConnection.onTrack = (event) {
      _remoteRenderer.srcObject = event.streams.first;
    };

    var offer = await _peerConnection.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
    await _peerConnection.setLocalDescription(offer);

    final response = await http.post(
      Uri.parse("${widget.janusApiUrl}/$_sessionId/$_handleId"),
      body: jsonEncode({
        "janus": "message",
        "body": {"request": "watch", "id": widget.streamId},
        "jsep": offer.toMap(),
        "transaction": "txn3",
      }),
    );

    final data = jsonDecode(response.body);
    final answer = data['jsep'];
    await _peerConnection.setRemoteDescription(
      RTCSessionDescription(answer['sdp'], answer['type']),
    );

    debugPrint("WebRTC negotiation completed.");
  }

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
  }

  @override
  void dispose() {
    _peerConnection.close();
    _remoteRenderer.dispose();
    super.dispose();
  }
}

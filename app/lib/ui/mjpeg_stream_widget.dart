import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class MjpegStreamWidget extends StatefulWidget {
  final String streamUrl;
  final BoxFit fit;
  final Duration timeout;
  const MjpegStreamWidget({
    Key? key,
    required this.streamUrl,
    this.fit = BoxFit.contain,
    this.timeout = const Duration(seconds: 5),
  }) : super(key: key);

  @override
  _MjpegStreamWidgetState createState() => _MjpegStreamWidgetState();
}

class _MjpegStreamWidgetState extends State<MjpegStreamWidget> {
  Uint8List? imageBytes;
  bool error = false;
  HttpClient? _httpClient;
  StreamSubscription<List<int>>? _subscription;
  final List<int> _buffer = [];
  String? _boundary;

  @override
  void initState() {
    super.initState();
    startStream();
  }

  Future<void> startStream() async {
    _httpClient = HttpClient();
    try {
      final request = await _httpClient!.getUrl(Uri.parse(widget.streamUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        setState(() {
          error = true;
        });
        return;
      }
      // 嘗試從 header 中取得 boundary 字串
      final contentType = response.headers.value("content-type");
      if (contentType != null) {
        final boundaryMatch = RegExp(r'boundary=(.*)').firstMatch(contentType);
        if (boundaryMatch != null) {
          _boundary = boundaryMatch.group(1);
          if (_boundary != null && !_boundary!.startsWith("--")) {
            _boundary = "--" + _boundary!;
          }
        }
      }
      // 如果無法取得 boundary，嘗試使用預設的 boundary 字串（有些 ESP32-cam 固定輸出 "--frame"）
      _boundary ??= "--frame";
      _subscription = response.listen((data) {
        _buffer.addAll(data);
        _extractFrame();
      }, onError: (e) {
        setState(() {
          error = true;
        });
      });
    } catch (e) {
      setState(() {
        error = true;
      });
    }
  }

  void _extractFrame() {
    // 取得 boundary 的位元組
    final boundaryBytes = _boundary!.codeUnits;
    int start = _indexOf(_buffer, boundaryBytes);
    if (start == -1) return;
    int end = _indexOf(_buffer, boundaryBytes, start + boundaryBytes.length);
    if (end == -1) return;
    // 從 boundary 後面尋找 JPEG 起始 (0xFF 0xD8)
    int jpegStart = _buffer.indexWhere((b) => b == 0xFF, start);
    if (jpegStart == -1 || jpegStart >= end) {
      _buffer.removeRange(0, end);
      return;
    }
    // 將 [jpegStart, end) 區間視為 JPEG frame
    final frameBytes = Uint8List.fromList(_buffer.sublist(jpegStart, end));
    setState(() {
      imageBytes = frameBytes;
      error = false;
    });
    // 移除已處理的資料
    _buffer.removeRange(0, end);
  }

  int _indexOf(List<int> buffer, List<int> pattern, [int start = 0]) {
    for (int i = start; i <= buffer.length - pattern.length; i++) {
      bool found = true;
      for (int j = 0; j < pattern.length; j++) {
        if (buffer[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _httpClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("Error loading stream", style: TextStyle(color: Colors.white)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  imageBytes = null;
                  error = false;
                  _buffer.clear();
                });
                startStream();
              },
              child: const Text("重新連接視訊"),
            )
          ],
        ),
      );
    }
    if (imageBytes != null) {
      return Image.memory(imageBytes!, fit: widget.fit);
    }
    return const Center(child: CircularProgressIndicator());
  }
}

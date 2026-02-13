// main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/motor_control_page.dart';

void main() {
  // 確保 Flutter 綁定已初始化 (有時在啟動異步操作前需要)
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dual Arm Controller',
      debugShowCheckedModeBanner: false, // 移除右上角 Debug 標籤
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        scaffoldBackgroundColor: Colors.grey[100],
        cardTheme: CardTheme(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), // 圓角加大
          margin: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 4.0), // 調整卡片間距
        ),
        sliderTheme: SliderThemeData(
            activeTrackColor: Colors.indigoAccent[100],
            inactiveTrackColor: Colors.grey[300],
            thumbColor: Colors.indigo,
            overlayColor: Colors.indigo.withAlpha(32),
            valueIndicatorColor: Colors.indigo,
            valueIndicatorTextStyle: const TextStyle(color: Colors.white),
            trackHeight: 4.0, // 滑軌高度
        ),
        toggleButtonsTheme: ToggleButtonsThemeData(
             selectedColor: Colors.white,
             color: Colors.indigo[800],
             fillColor: Colors.indigo[600], // 選中按鈕背景
             selectedBorderColor: Colors.indigo[700],
             borderColor: Colors.indigo[200],
             borderRadius: BorderRadius.circular(8.0),
             borderWidth: 1.5,
        ),
        appBarTheme: AppBarTheme( // 統一 AppBar 樣式
          backgroundColor: Colors.white,
          foregroundColor: Colors.indigo[800], // 圖標和標題顏色
          elevation: 1.0, // 減少陰影
          iconTheme: IconThemeData(color: Colors.indigo[700]), // Action 圖標顏色
        ),
        // 添加其他主題設定...
      ),
      home: const MotorControlPage(),
    );
  }
}
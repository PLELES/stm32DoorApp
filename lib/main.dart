import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() => runApp(const SensorDashboardApp());

class SensorDashboardApp extends StatelessWidget {
  const SensorDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'PingFang SC'),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // ================= 阿里云配置 =================
  final String productKey = "k1ws0UwWsXY";
  final String deviceName = "D-appDevice";

  final String deviceSecret = "e6758d6825b924c9a8f4245b766ae305";
  final String regionId = "cn-shanghai";

  // 订阅主题 (设备下发消息)
  String get subTopic => "/$productKey/$deviceName/user/get";

  MqttServerClient? client;
  String connectionStatusText = '尚未连接';
  bool isConnecting = false;

  // 传感器当前数据
  double currentTemp = 28.5;
  double currentHumidity = 65.0;
  double currentAirQuality = 120.0;
  double currentLight = 800.0;

  // 报警阈值 (支持解析 JSON 更新)
  double thresholdTemp = 30.0;
  double thresholdHumidity = 70.0;
  double thresholdAirQuality = 100.0;
  double thresholdLight = 1000.0;

  bool get isConnected => 
    client?.connectionStatus?.state == MqttConnectionState.connected;

  // 数据收发记录
  final List<String> _messages = [];
  final ScrollController _scrollController = ScrollController();

  void _addMessage(String msg) {
    if (!mounted) return;
    setState(() {
      _messages.add("${DateTime.now().toString().substring(11, 19)} $msg");
      if (_messages.length > 100) _messages.removeAt(0); // 限制最多显示100条
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearMessages() {
    setState(() {
      _messages.clear();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // --- MQTT 核心逻辑 ---

  Map<String, String> _generateAliyunParams() {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final clientId = "$deviceName|securemode=2,signmethod=hmacsha256,timestamp=$timestamp|";
    final username = "$deviceName&$productKey";
    final content = "clientId$deviceName" "deviceName$deviceName" "productKey$productKey" "timestamp$timestamp";
    final hmacSha256 = Hmac(sha256, utf8.encode(deviceSecret));
    final password = hmacSha256.convert(utf8.encode(content)).toString().toUpperCase();
    return {'clientId': clientId, 'username': username, 'password': password};
  }

  Future<void> toggleConnection() async {
    if (isConnected) {
      client?.disconnect();
      return;
    }
    await _doConnect();
  }

  Future<void> _doConnect() async {
    setState(() {
      isConnecting = true;
      connectionStatusText = "正在握手...";
    });

    final params = _generateAliyunParams();
    final broker = "$productKey.iot-as-mqtt.$regionId.aliyuncs.com";
    
    client = MqttServerClient.withPort(broker, params['clientId']!, 1883);
    client?.keepAlivePeriod = 60;
    client?.onDisconnected = () => setState(() => connectionStatusText = '已离线');
    client?.onConnected = () {
      setState(() => connectionStatusText = '云端在线');
      _setupMessageListener(); 
    };

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(params['clientId']!)
        .authenticateAs(params['username']!, params['password']!)
        .withWillQos(MqttQos.atMostOnce);
    client?.connectionMessage = connMessage;

    try {
      await client?.connect();
      client?.subscribe(subTopic, MqttQos.atLeastOnce);
    } catch (e) {
      setState(() => connectionStatusText = '连接失败');
      client?.disconnect();
    } finally {
      setState(() => isConnecting = false);
    }
  }

  // 接收并解析 JSON 阈值
  void _setupMessageListener() {
    client?.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
      final String payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

      _addMessage("收到: $payload");

      try {
        final Map<String, dynamic> data = jsonDecode(payload);
        if (data.containsKey('sensor')) {
          final sensor = data['sensor'];
          setState(() {
            if (sensor['temp'] != null) currentTemp = sensor['temp'].toDouble();
            if (sensor['humi'] != null) currentHumidity = sensor['humi'].toDouble();
            if (sensor['light'] != null) currentLight = sensor['light'].toDouble();
            if (sensor['air'] != null) currentAirQuality = sensor['air'].toDouble();
          });
        }

        if (data.containsKey('thresholds')) {
          final thr = data['thresholds'];
          setState(() {
            if (thr['temp'] != null) thresholdTemp = thr['temp'].toDouble();
            if (thr['humi'] != null) thresholdHumidity = thr['humi'].toDouble();
            if (thr['light'] != null) thresholdLight = thr['light'].toDouble();
            if (thr['air'] != null) thresholdAirQuality = thr['air'].toDouble();
          });
        }
      } catch (e) {
        debugPrint('Parse Error: $e');
      }
    });
  }

  void _publishThreshold(String type, double value) {
    if (!isConnected) return;
    final pubTopic = "/$productKey/$deviceName/user/update";
    final payload = jsonEncode({
      "type": type,
      "threshold": value.toStringAsFixed(1),
    });
    
    _addMessage("发送: $payload");
    
    final builder = MqttClientPayloadBuilder()..addString(payload);
    client?.publishMessage(pubTopic, MqttQos.atLeastOnce, builder.payload!);
  }

  // --- 优化后的 UI 组件 ---

  Widget _buildConnectPanel() {
    Color statusColor = isConnected ? Colors.greenAccent : (isConnecting ? Colors.orangeAccent : Colors.redAccent);
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      decoration: BoxDecoration(
        color: const Color(0xFF1E272E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle, boxShadow: [BoxShadow(color: statusColor, blurRadius: 6)]),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("CONNECTION STATUS", style: TextStyle(fontSize: 10, color: Colors.white38, letterSpacing: 1.2)),
                Text(connectionStatusText, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: isConnecting ? null : toggleConnection,
            style: ElevatedButton.styleFrom(
              backgroundColor: isConnected ? Colors.redAccent.withOpacity(0.2) : Colors.blueAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(isConnected ? "断开" : "连接"),
          ),
        ],
      ),
    );
  }

  // 增强版传感器卡片
  Widget _buildSensorCard({
    required String label,
    required IconData icon,
    required String type,
    required double current,
    required double threshold,
    required String unit,
    required double min,
    required double max,
    required Function(double) onUIChange,
  }) {
    bool isWarning = current > threshold;
    Color themeColor = isWarning ? Colors.redAccent : Colors.cyanAccent;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F25),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: isWarning ? Colors.redAccent.withOpacity(0.4) : Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          // 第一行：图标 + 名称 + 警告标志
          Row(
            children: [
              Icon(icon, color: Colors.white54, size: 20),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const Spacer(),
              if (isWarning) 
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(8)),
                  child: const Text("超标", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 第二行：当前值 vs 阈值显示
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(current.toStringAsFixed(1), style: TextStyle(fontSize: 36, color: themeColor, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(unit, style: const TextStyle(color: Colors.white24, fontSize: 14)),
              ),
              const Spacer(),
              // 阈值显示区域
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text("设定阈值", style: TextStyle(color: Colors.white38, fontSize: 11)),
                  Text(threshold.toStringAsFixed(1), style: const TextStyle(color: Colors.orangeAccent, fontSize: 18, fontWeight: FontWeight.w500)),
                ],
              )
            ],
          ),
          const SizedBox(height: 10),
          // 第三行：调节滑块
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: threshold.clamp(min, max),
              min: min, max: max,
              activeColor: Colors.orangeAccent,
              inactiveColor: Colors.white10,
              onChanged: (v) => onUIChange(v),
              onChangeEnd: (v) => _publishThreshold(type, v),
            ),
          ),
        ],
      ),
    );
  }

  // 消息日志组件
  Widget _buildMessageLog() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E272E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("收发日志", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white54, size: 20),
                onPressed: _clearMessages,
                tooltip: "一键清除",
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 150,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: _messages.isEmpty
                ? const Center(child: Text("暂无消息", style: TextStyle(color: Colors.white38)))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      // 简单区分收发颜色
                      final isSend = msg.contains("发送:");
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          msg,
                          style: TextStyle(
                            color: isSend ? Colors.blueAccent : Colors.greenAccent,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1216),
      appBar: AppBar(
        title: const Text("IoT 环境控制台", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            _buildConnectPanel(),
            _buildSensorCard(
              label: '环境温度', icon: Icons.thermostat, type: 'temp', 
              current: currentTemp, threshold: thresholdTemp, unit: '℃', 
              min: -10, max: 50, onUIChange: (v) => setState(() => thresholdTemp = v),
            ),
            _buildSensorCard(
              label: '相对湿度', icon: Icons.water_drop, type: 'humi', 
              current: currentHumidity, threshold: thresholdHumidity, unit: '%', 
              min: 0, max: 100, onUIChange: (v) => setState(() => thresholdHumidity = v),
            ),
            _buildSensorCard(
              label: '空气质量', icon: Icons.air, type: 'air', 
              current: currentAirQuality, threshold: thresholdAirQuality, unit: 'AQI', 
              min: 0, max: 500, onUIChange: (v) => setState(() => thresholdAirQuality = v),
            ),
            _buildSensorCard(
              label: '光照强度', icon: Icons.light_mode, type: 'light', 
              current: currentLight, threshold: thresholdLight, unit: 'Lux', 
              min: 0, max: 2000, onUIChange: (v) => setState(() => thresholdLight = v),
            ),
            _buildMessageLog(),
            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }
}

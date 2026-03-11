import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '智能门锁控制',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark, // 黑色科技感主题
      ),
      home: const AliCloudMqttPage(),
    );
  }
}

class AliCloudMqttPage extends StatefulWidget {
  const AliCloudMqttPage({super.key});

  @override
  State<AliCloudMqttPage> createState() => _AliCloudMqttPageState();
}

class _AliCloudMqttPageState extends State<AliCloudMqttPage> {
  // ================= 替换为你的设备信息 =================
  final String productKey = "k1ws0VxImus";
  final String deviceName = "appDevice";
  final String deviceSecret = "3dd085aed29cb4947f79450065dfc956";
  final String regionId = "cn-shanghai";
  // ====================================================

  MqttServerClient? client;
  String connectionState = '未连接';
  List<String> logs = [];
  
  // 业务相关变量
  bool isLocked = true; // 门锁状态
  String inputPassword = ""; // 当前输入的密码

  String get brokerUrl => "$productKey.iot-as-mqtt.$regionId.aliyuncs.com";
  String get subTopic => "/$productKey/$deviceName/user/get";
  String get pubTopic => "/$productKey/$deviceName/user/update";

  @override
  void initState() {
    super.initState();
    // 自动连接
    connectMqtt();
  }

  // --- 核心业务逻辑 ---

  /// 模拟开门动作
  void _openDoor() {
    setState(() {
      isLocked = false;
    });
    // 3秒后自动重新上锁
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => isLocked = true);
      }
    });
  }

  /// 处理矩阵键盘点击
  void _handleKeyPress(String value) {
    if (inputPassword.length < 6) {
      setState(() {
        inputPassword += value;
      });
    }
  }

  /// 删除最后一位
  void _handleDelete() {
    if (inputPassword.isNotEmpty) {
      setState(() {
        inputPassword = inputPassword.substring(0, inputPassword.length - 1);
      });
    }
  }

  /// 提交密码至阿里云
  void _handleSubmit() {
    if (inputPassword.isEmpty) return;
    
    final payload = jsonEncode({
      "type": "password_verify",
      "password": inputPassword,
      "timestamp": DateTime.now().millisecondsSinceEpoch
    });
    
    _publish(payload);
    
    setState(() {
      logs.insert(0, "发送密码验证: $inputPassword");
      inputPassword = ""; // 清空输入
    });
  }

  // --- MQTT 基础方法 ---

  Map<String, String> generateAliyunMqttParams() {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final clientId = "$deviceName|securemode=2,signmethod=hmacsha256,timestamp=$timestamp|";
    final username = "$deviceName&$productKey";
    final content = "clientId$deviceName" "deviceName$deviceName" "productKey$productKey" "timestamp$timestamp";
    final hmacSha256 = Hmac(sha256, utf8.encode(deviceSecret));
    final password = hmacSha256.convert(utf8.encode(content)).toString().toUpperCase();

    return {'clientId': clientId, 'username': username, 'password': password};
  }

  Future<void> connectMqtt() async {
    final params = generateAliyunMqttParams();
    client = MqttServerClient.withPort(brokerUrl, params['clientId']!, 1883);
    client?.keepAlivePeriod = 60;
    client?.onDisconnected = () => setState(() => connectionState = '连接断开');

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(params['clientId']!)
        .authenticateAs(params['username']!, params['password']!)
        .withWillQos(MqttQos.atMostOnce);
    client?.connectionMessage = connMessage;

    try {
      setState(() => connectionState = '正在连接...');
      await client?.connect();
      if (client?.connectionStatus!.state == MqttConnectionState.connected) {
        setState(() => connectionState = '云端已就绪');
        client?.subscribe(subTopic, MqttQos.atLeastOnce);
        
        // 监听消息
        client?.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
          final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
          final String payload = MqttPublishPayload.bytesToStringAsString(message.payload.message);
          
          setState(() => logs.insert(0, "收到指令: $payload"));

          // 1. 判断是否收到 unlock 指令
          if (payload.contains("unlock")) {
            _openDoor();
          }
        });
      }
    } catch (e) {
      setState(() => connectionState = '连接失败');
    }
  }

  void _publish(String message) {
    if (client?.connectionStatus!.state != MqttConnectionState.connected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    client?.publishMessage(pubTopic, MqttQos.atLeastOnce, builder.payload!);
  }

  // --- UI 组件 ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E), // 深色背景
      appBar: AppBar(
        title: const Text('智能安全门锁'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: connectMqtt)
        ],
      ),
      body: Column(
        children: [
          // 1. 状态指示器
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(connectionState, style: TextStyle(color: connectionState == '云端已就绪' ? Colors.green : Colors.redAccent)),
          ),

          // 2. 门锁动态图标
          const SizedBox(height: 20),
          _buildLockAnimation(),
          const SizedBox(height: 10),
          Text(isLocked ? "已上锁" : "已开锁", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),

          // 3. 密码显示区域
          const SizedBox(height: 30),
          _buildPasswordDisplay(),

          // 4. 矩阵键盘
          const SizedBox(height: 20),
          Expanded(child: _buildKeypad()),

          // 5. 简易日志查看
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ListView.builder(
              itemCount: logs.length > 3 ? 3 : logs.length,
              itemBuilder: (context, i) => Text(logs[i], style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
          )
        ],
      ),
    );
  }

  /// 门锁动画组件
  Widget _buildLockAnimation() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isLocked ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
        border: Border.all(color: isLocked ? Colors.red : Colors.green, width: 2),
        boxShadow: [
          BoxShadow(
            color: isLocked ? Colors.red.withOpacity(0.3) : Colors.green.withOpacity(0.3),
            blurRadius: 20,
            spreadRadius: 5,
          )
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
        child: Icon(
          isLocked ? Icons.lock : Icons.lock_open,
          key: ValueKey(isLocked),
          size: 80,
          color: isLocked ? Colors.red : Colors.green,
        ),
      ),
    );
  }

  /// 密码点阵显示
  Widget _buildPasswordDisplay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        bool isFilled = index < inputPassword.length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled ? Colors.blueAccent : Colors.white12,
            border: Border.all(color: Colors.blueAccent),
          ),
        );
      }),
    );
  }

  /// 矩阵键盘构建
  Widget _buildKeypad() {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'DEL', '0', 'OK'];
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 1.2,
        crossAxisSpacing: 20,
        mainAxisSpacing: 20,
      ),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        String key = keys[index];
        bool isSpecial = key == 'DEL' || key == 'OK';

        return InkWell(
          onTap: () {
            if (key == 'DEL') _handleDelete();
            else if (key == 'OK') _handleSubmit();
            else _handleKeyPress(key);
          },
          borderRadius: BorderRadius.circular(50),
          child: Container(
            decoration: BoxDecoration(
              color: isSpecial ? (key == 'OK' ? Colors.green : Colors.redAccent.withOpacity(0.8)) : Colors.white.withOpacity(0.05),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: key == 'DEL' 
              ? const Icon(Icons.backspace_outlined) 
              : (key == 'OK' ? const Icon(Icons.check, size: 30) : Text(key, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
          ),
        );
      },
    );
  }
}
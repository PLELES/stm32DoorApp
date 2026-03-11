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
      title: '阿里云 MQTT Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
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
  final String regionId = "cn-shanghai"; // 你的地域ID，比如 cn-shanghai, cn-hangzhou
  // ====================================================

  MqttServerClient? client;
  String connectionState = '未连接';
  List<String> messages = [];

  // 获取阿里云服务器地址
  String get brokerUrl => "$productKey.iot-as-mqtt.$regionId.aliyuncs.com";
  // 获取主题：这里填写你在阿里云后台创建或默认的 Topic
  String get subTopic => "/$productKey/$deviceName/user/get";
  String get pubTopic => "/$productKey/$deviceName/user/update";

  @override
  void initState() {
    super.initState();
  }

  /// 计算阿里云 MQTT 连接参数
  Map<String, String> generateAliyunMqttParams() {
    // 1. 生成 clientId
    // 格式：clientId+"|securemode=2,signmethod=hmacsha256,timestamp=1234567890|"
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final clientId = "$deviceName|securemode=2,signmethod=hmacsha256,timestamp=$timestamp|";

    // 2. 生成 username
    // 格式：deviceName+"&"+productKey
    final username = "$deviceName&$productKey";

    // 3. 生成 password (签名)
    // 需要使用 HmacSHA256 加密 clientId+deviceName+productKey+timestamp
    final content =
        "clientId$deviceName" "deviceName$deviceName" "productKey$productKey" "timestamp$timestamp";
    final hmacSha256 = Hmac(sha256, utf8.encode(deviceSecret));
    final digest = hmacSha256.convert(utf8.encode(content));
    final password = digest.toString().toUpperCase();

    return {
      'clientId': clientId,
      'username': username,
      'password': password,
    };
  }

  /// 连接 MQTT 并订阅
  Future<void> connectMqtt() async {
    final params = generateAliyunMqttParams();
    
    // 端口传 1883
    client = MqttServerClient.withPort(brokerUrl, params['clientId']!, 1883);

    client?.logging(on: true);
    client?.keepAlivePeriod = 60; // 阿里云要求保持在 60-300 秒间
    client?.onDisconnected = onDisconnected;
    client?.onConnected = onConnected;
    client?.onSubscribed = onSubscribed;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(params['clientId']!)
        .authenticateAs(params['username']!, params['password']!)
        .withWillQos(MqttQos.atMostOnce);
    client?.connectionMessage = connMessage;

    try {
      setState(() => connectionState = '连接中...');
      await client?.connect();
    } catch (e) {
      debugPrint('连接异常: $e');
      client?.disconnect();
      setState(() => connectionState = '连接异常: $e');
    }

    if (client?.connectionStatus!.state == MqttConnectionState.connected) {
      setState(() => connectionState = '已连接');
      
      // 订阅主题 (Sub)
      client?.subscribe(subTopic, MqttQos.atLeastOnce);

      // 监听接收到的消息
      client?.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
        final String payload =
            MqttPublishPayload.bytesToStringAsString(message.payload.message);

        debugPrint('收到主题 ${c[0].topic} 的消息: $payload');
        setState(() {
          messages.insert(0, '收到数据: $payload');
        });
      });
    } else {
      setState(() => connectionState = '连接失败，状态: ${client?.connectionStatus!.state}');
      client?.disconnect();
    }
  }

  /// 发布消息 (Pub)
  void publishMessage() {
    if (client?.connectionStatus!.state != MqttConnectionState.connected) {
      debugPrint('尚未连接服务器');
      return;
    }

    final builder = MqttClientPayloadBuilder();
    // 这里可以是普通的字符串，也可以是 JSON 格式（如物模型数据）
    builder.addString('{"message": "Hello from Flutter", "value": 100}');

    client?.publishMessage(pubTopic, MqttQos.atLeastOnce, builder.payload!);
    
    setState(() {
      messages.insert(0, '发送数据至 $pubTopic 成功');
    });
  }

  void onConnected() {
    debugPrint('MQTT 已连接');
  }

  void onDisconnected() {
    debugPrint('MQTT 已断开');
    setState(() => connectionState = '已断开');
  }

  void onSubscribed(String topic) {
    debugPrint('已成功订阅主题: $topic');
  }

  @override
  void dispose() {
    client?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('阿里云 MQTT 连接演示')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text('状态: $connectionState', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: connectMqtt,
                  child: const Text('1. 连接并订阅'),
                ),
                ElevatedButton(
                  onPressed: publishMessage,
                  child: const Text('2. 发送(Pub)'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(messages[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
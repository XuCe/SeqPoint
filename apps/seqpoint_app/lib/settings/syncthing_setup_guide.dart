import 'package:flutter/material.dart';

class SyncthingSetupGuide extends StatelessWidget {
  const SyncthingSetupGuide({super.key});

  @override
  Widget build(BuildContext context) => const ExpansionTile(
    title: Text('如何搭建 Syncthing · 端口怎么开放'),
    childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '1. 在常在线的电脑或服务器安装官方 Syncthing，启动后在该设备打开 '
        'http://127.0.0.1:8384。序点客户端已内嵌引擎，无需另装。\n\n'
        '2. 设置可写、持久保存的默认文件夹路径；容器需持久化配置和数据目录。'
        '节点只保存序点加密后的同步数据。\n\n'
        '3. 推荐让客户端和节点加入同一 VPN。管理接口仅允许本机、受信内网或 '
        'VPN 访问，设置用户名和强密码；使用 HTTPS 时需有效证书。'
        '不要把管理端口映射到公网。\n\n'
        '4. 在 Syncthing「操作 → 设置 → 常规」复制 API Key，'
        '将节点经内网或 VPN 可达的管理地址和 Key 填入本页。'
        '未写协议时按 HTTPS 处理；私网 IP 可显式填写 http://。\n\n'
        '5. 两台序点先完成局域网配对，再分别保存并授权同一个节点。'
        '同步期间保持管理 API 可达；节点常在线时，客户端无需同时在线。',
      ),
      SizedBox(height: 16),
      Text('最小端口开放范围', style: TextStyle(fontWeight: FontWeight.w600)),
      SizedBox(height: 8),
      Text(
        '• 优先全部走 VPN，公网无需映射 Syncthing 端口。\n'
        '• 需要公网直连：22000/TCP 用于传输；22000/UDP 用于 QUIC，按需开放。'
        '仅使用 TCP 时可不开放 UDP。自定义端口以实际监听配置为准。\n'
        '• 21027/UDP 仅用于局域网发现，不映射到公网。\n'
        '• 8384/TCP 是管理界面和 REST API 共用端口，仅允许受信内网或 VPN。\n'
        '• Syncthing 可借助中继连接而不配置入站映射；本页的管理 API 仍需私网可达。'
        '严格控制端口时，同时检查并关闭不需要的 UPnP/NAT-PMP 自动映射。',
      ),
      SizedBox(height: 12),
      SelectableText('官方入门：https://docs.syncthing.net/intro/getting-started.html\n'
        '官方端口说明：https://docs.syncthing.net/users/firewall.html'),
    ],
  );
}

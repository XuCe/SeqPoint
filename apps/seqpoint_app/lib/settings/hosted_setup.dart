import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_scope.dart';
import '../sync/app_sync_service.dart';
import '../sync/hosted_invite.dart';

class HostedSetup extends StatefulWidget {
  const HostedSetup({super.key, this.service, this.link = ''});
  final AppSyncService? service;
  final String link;
  @override
  State<HostedSetup> createState() => _HostedSetupState();
}

class _HostedSetupState extends State<HostedSetup> {
  late final input = TextEditingController(text: widget.link);
  bool working = false;
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> enable(AppSyncService service) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      await service.enableHosted(input.text.trim());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          working = false;
          error = e is FormatException ? e.message : '开通失败，请检查网络和设备身份后重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service ?? AppScope.of(context).sync;
    HostedInvite? invite;
    try {
      invite = HostedInvite.parse(input.text);
    } on FormatException {
      invite = null;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('启用云同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('首台设备使用运营方邀请。添加第二台设备时，请先与已有设备配对。'),
          TextField(
            controller: input,
            enabled: !working,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {
              error = null;
            }),
            decoration: const InputDecoration(labelText: '邀请链接'),
          ),
          if (input.text.isEmpty)
            TextButton.icon(icon: const Icon(Icons.content_paste), label: const Text('粘贴刚复制的邀请'),
              onPressed: working ? null : () async {
                final clip = await Clipboard.getData(Clipboard.kTextPlain);
                if (!mounted) return;
                final link = clip?.text?.trim() ?? '';
                try {
                  HostedInvite.parse(link);
                  setState(() {input.text = link; error = null;});
                } on FormatException {
                  setState(() => error = '剪贴板中没有完整的序点邀请链接');
                }
              }),
          if (invite != null)
            ListTile(title: const Text('将连接到'), subtitle: Text(invite.origin)),
          if (error != null) Text(error!),
          FilledButton(
            onPressed:
                working ||
                    invite == null ||
                    service == null ||
                    (!invite.gateway && !service.syncthingSupported)
                ? null
                : () => enable(service),
            child: Text(working ? '正在开通…' : '确认启用'),
          ),
        ],
      ),
    );
  }
}

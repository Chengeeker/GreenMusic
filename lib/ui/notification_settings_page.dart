import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_page_scaffold.dart';
import '../core/design_system/components/review_preference_tile.dart';
import '../core/theme/theme_provider.dart';
import '../player/download_storage.dart';
import 'widgets.dart';

class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key});
  @override
  ConsumerState<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState
    extends ConsumerState<NotificationSettingsPage>
    with WidgetsBindingObserver {
  late Future<bool> _enabled;
  DownloadStorage get _access => DownloadStorage(ref.read(preferencesProvider));
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enabled = _access.notifications();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {
        _enabled = _access.notifications();
      });
    }
  }

  @override
  Widget build(BuildContext context) => ReviewPageScaffold(
    title: '播放通知',
    bodyBuilder: (context, insets) => ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ).add(insets),
      children: [
        const AppSectionHeading('通知权限'),
        AppSectionCard(
          child: FutureBuilder<bool>(
            future: _enabled,
            builder: (context, snapshot) => ReviewPreferenceTile(
              title: snapshot.data == true ? '通知已开启' : '开启播放通知',
              subtitle: '显示系统原生媒体卡片、专辑封面和播放控制',
              leading: const Icon(Icons.notifications_outlined),
              onTap: () => runAction(context, () async {
                await _access.notifications(request: true);
                if (mounted) {
                  setState(() {
                    _enabled = _access.notifications();
                  });
                }
              }),
            ),
          ),
        ),
      ],
    ),
  );
}

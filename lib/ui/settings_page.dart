import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../core/design_system/components/review_page_scaffold.dart';
import '../core/design_system/components/review_preference_tile.dart';
import 'theme_settings_page.dart';
import 'storage_settings_page.dart';
import 'webdav_backup_page.dart';
import '../providers.dart';
import 'login_page.dart';
import 'widgets.dart';
import 'downloads_page.dart';
import 'download_settings_page.dart';
import 'notification_settings_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider), handler = ref.read(playerProvider);
    Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 24),
      child: AppSectionHeading(title),
    );
    return ReviewPageScaffold(
      title: '设置',
      bodyBuilder: (context, insets) => ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          insets.top + 12,
          16,
          24 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          heading('偏好与功能'),
          AppSectionCard(
            child: Column(
              children: [
                ReviewPreferenceTile(
                  title: '个性化',
                  leading: const Icon(Icons.palette_outlined),
                  onTap: () => openPage(context, const ThemeSettingsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: '播放设置',
                  leading: const Icon(Icons.headphones_outlined),
                  onTap: () => openPage(context, const PlaybackSettingsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: '播放通知',
                  leading: const Icon(Icons.notifications_outlined),
                  onTap: () =>
                      openPage(context, const NotificationSettingsPage()),
                ),
              ],
            ),
          ),
          heading('存储与备份'),
          AppSectionCard(
            child: Column(
              children: [
                ReviewPreferenceTile(
                  title: '存储设置',
                  leading: const Icon(Icons.folder_open_outlined),
                  onTap: () => openPage(context, const StorageSettingsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: '下载歌曲',
                  subtitle: '查看、播放与删除已下载歌曲',
                  leading: const Icon(Icons.download_outlined),
                  onTap: () => openPage(context, const DownloadsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: '下载设置',
                  subtitle: '音质、保存位置与 LRC 歌词',
                  leading: const Icon(Icons.downloading_outlined),
                  onTap: () => openPage(context, const DownloadSettingsPage()),
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: '缓存管理',
                  subtitle: '封面内存缓存与下载管理入口',
                  leading: const Icon(Icons.cleaning_services_outlined),
                  onTap: () => openPage(context, const CacheManagementPage()),
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: 'WebDAV备份',
                  subtitle: '备份与恢复设置、队列和最近播放',
                  leading: const Icon(Icons.cloud_sync_outlined),
                  onTap: () => openPage(context, const WebDavBackupPage()),
                ),
              ],
            ),
          ),
          heading('账号'),
          AppSectionCard(
            child: Column(
              children: [
                if (auth.session == null)
                  ReviewPreferenceTile(
                    title: '登录 QQ 音乐',
                    leading: const Icon(Icons.login_rounded),
                    onTap: () => openPage(context, const LoginPage()),
                  )
                else ...[
                  ReviewPreferenceTile(
                    title: auth.session!.nickname,
                    subtitle: '刷新账号与登录状态',
                    leading: const Icon(Icons.account_circle_outlined),
                    onTap: _busy
                        ? null
                        : () => runAction(
                            context,
                            auth.ensureSession,
                            success: '账号状态已更新',
                          ),
                  ),
                  const Divider(height: 1, indent: 56),
                  ReviewPreferenceTile(
                    title: '退出登录',
                    leading: const Icon(Icons.logout_rounded),
                    onTap: _busy
                        ? null
                        : () async {
                            if (!await confirm(
                                  context,
                                  '退出登录',
                                  '退出并停止播放，清除本机登录凭据？已下载歌曲保留，重新登录原账号后可见。',
                                ) ||
                                !context.mounted) {
                              return;
                            }
                            setState(() => _busy = true);
                            await runAction(context, () async {
                              await handler.stop();
                              await auth.logout();
                              await handler.cancelDownload();
                            }, success: '已退出登录');
                            if (mounted) {
                              setState(() {
                                _busy = false;
                              });
                            }
                          },
                  ),
                ],
              ],
            ),
          ),
          heading('关于'),
          AppSectionCard(
            child: Column(
              children: [
                const ReviewPreferenceTile(
                  title: 'GreenMusic',
                  subtitle: '1.0.0 · QQ 音乐第三方客户端',
                  leading: Icon(Icons.music_note_rounded),
                  trailing: SizedBox.shrink(),
                  onTap: null,
                ),
                const Divider(height: 1, indent: 56),
                ReviewPreferenceTile(
                  title: '开源许可',
                  subtitle: 'Lilt · AGPL-3.0 / Review · MIT',
                  leading: const Icon(Icons.description_outlined),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'GreenMusic',
                    applicationVersion: '1.0.0',
                    applicationLegalese: '音乐接口复用 Lilt；Material 3 界面复用 Review。',
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
            child: Text(
              '音乐版权归各权利人所有。可播放音源与音质由 QQ 音乐账号、会员和地区权限决定。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

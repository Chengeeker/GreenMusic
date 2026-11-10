// Form and grouped backup controls reused from Review webdav_backup_page.dart (MIT).
import 'package:flutter/material.dart';

import '../player/lyrics_settings.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/design_system/components/review_frosted_app_bar.dart';
import '../core/design_system/components/review_choice_tile.dart';
import '../core/design_system/components/app_section_card.dart';
import '../core/services/backup_service.dart';
import '../core/services/webdav_service.dart';
import '../core/theme/theme_provider.dart';
import '../core/utils/app_toast.dart';
import 'widgets.dart';

class WebDavBackupPage extends ConsumerStatefulWidget {
  const WebDavBackupPage({super.key});
  @override
  ConsumerState<WebDavBackupPage> createState() => _WebDavBackupPageState();
}

class _WebDavBackupPageState extends ConsumerState<WebDavBackupPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController,
      _usernameController,
      _passwordController,
      _dirController;
  final _webDavService = WebDavService();
  bool _isTesting = false,
      _isBackingUp = false,
      _isRestoring = false,
      _includeCredentials = false,
      _loadingConfig = true;
  bool get _isBusy =>
      _isTesting || _isBackingUp || _isRestoring || _loadingConfig;
  @override
  void initState() {
    super.initState();
    final storage = ref.read(backupServiceProvider);
    _urlController = TextEditingController(text: storage.getWebDavUrl());
    _usernameController = TextEditingController(
      text: storage.getWebDavUsername(),
    );
    _passwordController = TextEditingController();
    _dirController = TextEditingController(text: storage.getWebDavDirectory());
    _loadPassword();
  }

  Future<void> _loadPassword() async {
    try {
      final password = await ref
          .read(backupServiceProvider)
          .getWebDavPassword();
      if (mounted) _passwordController.text = password;
    } catch (_) {
      if (mounted) AppToast.show(context, '读取 WebDAV 密码失败，请重新填写');
    } finally {
      if (mounted) setState(() => _loadingConfig = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    final s = ref.read(backupServiceProvider);
    WebDavService.directoryUri(_urlController.text, _dirController.text);
    await s.setWebDavUrl(_urlController.text.trim());
    await s.setWebDavUsername(_usernameController.text.trim());
    await s.setWebDavPassword(_passwordController.text);
    await s.setWebDavDirectory(
      _dirController.text.trim().isEmpty
          ? 'GreenMusic'
          : _dirController.text.trim(),
    );
  }

  Future<void> _testConnection() async {
    if (_isBusy || !_formKey.currentState!.validate()) return;
    setState(() => _isTesting = true);
    try {
      await _saveConfig();
      final ok = await _webDavService.testConnection(
        serverUrl: _urlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        AppToast.show(context, ok ? 'WebDAV 服务器连接成功' : '连接失败，请检查最终服务器地址和账号密码');
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '配置保存失败，请检查输入后重试');
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _performBackup() async {
    if (_isBusy || !_formKey.currentState!.validate()) return;
    setState(() => _isBackingUp = true);
    try {
      await _saveConfig();
      final data = await ref
          .read(backupServiceProvider)
          .exportAllData(includeCredentials: _includeCredentials);
      final ok = await _webDavService.uploadBackup(
        serverUrl: _urlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        directoryName: _dirController.text.trim(),
        data: data,
      );
      if (mounted) {
        AppToast.show(context, ok ? '备份已上传到 WebDAV 云盘' : '备份上传失败，请检查连接和目录权限');
      }
    } catch (_) {
      if (mounted) AppToast.show(context, '备份失败，未能读取完整数据');
    } finally {
      if (mounted) setState(() => _isBackingUp = false);
    }
  }

  Future<void> _performRestore() async {
    if (_isBusy || !_formKey.currentState!.validate()) return;
    if (!await confirm(
          context,
          '从 WebDAV 恢复备份？',
          '恢复会停止播放并覆盖备份内的设置、队列和历史。全量备份还会替换 QQ 音乐登录凭据和 WebDAV 密码。安全备份保留当前登录；服务器地址变化时清除本机 WebDAV 密码。',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _isRestoring = true);
    try {
      await _saveConfig();
      final data = await _webDavService.downloadLatestBackup(
        serverUrl: _urlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        directoryName: _dirController.text.trim(),
      );
      if (data == null) throw const FormatException('No backup');
      final storage = ref.read(backupServiceProvider);
      await storage.restoreAllData(data);
      if (!mounted) return;
      if (storage.prefs.getBool('liquidGlass') == true &&
          storage.prefs.getBool('floatingNav') != false) {
        await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
        if (!mounted) return;
      }
      ref.read(themeProvider.notifier).reload();
      ref.read(lyricsSettingsProvider.notifier).reload();
      try {
        await ref
            .read(themeProvider.notifier)
            .setScreenRefreshRateMode(
              storage.prefs.getInt('screenRefreshRateMode') ?? 0,
            );
      } catch (_) {
        await ref
            .read(themeProvider.notifier)
            .setInt('screenRefreshRateMode', 0);
      }
      if (!mounted) return;
      _urlController.text = storage.getWebDavUrl();
      _usernameController.text = storage.getWebDavUsername();
      _dirController.text = storage.getWebDavDirectory();
      _passwordController.text = await storage.getWebDavPassword();
      if (mounted) AppToast.show(context, '备份已恢复；账号有效性以 QQ 音乐校验为准');
    } catch (_) {
      if (mounted) AppToast.show(context, '恢复失败，备份无效、下载失败或数据写入失败');
    } finally {
      if (mounted) setState(() => _isRestoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ReviewFrostedAppBar(
        title: const Text(
          'WebDAV 云端备份与恢复',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            reviewContentTopInset(context) + 14,
            16,
            14,
          ),
          children: [
            // 1. Info Banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.cloud_sync_rounded,
                    color: colorScheme.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '备份内容',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '备份应用设置、播放队列和最近播放，不包含封面或歌曲缓存。',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            AbsorbPointer(
              absorbing: _isBackingUp || _isRestoring,
              child: AppSectionCard(
                child: Column(
                  children: [
                    ReviewChoiceTile<bool>(
                      title: '全量安全备份',
                      summary: 'QQ 音乐登录凭据 和 WebDAV 密码不会上传。',
                      value: false,
                      groupValue: _includeCredentials,
                      onSelected: () =>
                          setState(() => _includeCredentials = false),
                    ),
                    ReviewChoiceTile<bool>(
                      title: '全量备份',
                      summary:
                          '同时上传 QQ 音乐登录凭据 和 WebDAV 密码。备份文件含明文凭据，请妥善保管云盘及历史备份。',
                      value: true,
                      groupValue: _includeCredentials,
                      onSelected: () =>
                          setState(() => _includeCredentials = true),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 2. Configuration Card
            const AppSectionHeading('WebDAV 服务器配置'),
            AppSectionCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      enabled: !_isBusy,
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: '服务器 URL',
                        hintText: '例如: https://dav.jianguoyun.com/dav/',
                        prefixIcon: Icon(Icons.link_rounded),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return '请输入 WebDAV 服务器地址';
                        }
                        if (!WebDavService.isSecureUrl(v)) {
                          return 'WebDAV 请使用 HTTPS 地址';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      enabled: !_isBusy,
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: '账号 / 邮箱',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入账号' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      enabled: !_isBusy,
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '应用密码 / Token',
                        prefixIcon: Icon(Icons.lock_outline_rounded),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? '请输入密码或授权 Token'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      enabled: !_isBusy,
                      controller: _dirController,
                      decoration: const InputDecoration(
                        labelText: '备份文件夹名称',
                        hintText: '默认: GreenMusic',
                        prefixIcon: Icon(Icons.folder_outlined),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: _isTesting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.wifi_tethering_rounded,
                                size: 18,
                              ),
                        label: Text(_isTesting ? '正在测试连接...' : '测试服务器连接'),
                        onPressed: _isBusy ? null : _testConnection,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 3. Actions Section
            const AppSectionHeading('云端备份与还原操作'),
            AppSectionCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: _isBackingUp
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.cloud_upload_rounded),
                            label: Text(_isBackingUp ? '正在上传...' : '立即备份到云端'),
                            onPressed: _isBusy ? null : _performBackup,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: _isRestoring
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.cloud_download_rounded),
                            label: Text(_isRestoring ? '正在拉取...' : '从云端恢复备份'),
                            onPressed: _isBusy ? null : _performRestore,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

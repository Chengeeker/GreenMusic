import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/review_page_scaffold.dart';
import '../data/auth_service.dart';
import '../data/qq_music_api.dart';
import '../providers.dart';
import 'web_login_page.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage>
    with WidgetsBindingObserver {
  QrLogin? _qr;
  Timer? _timer;
  bool _wechat = false, _loading = false, _polling = false, _foreground = true;
  String? _error;
  int _generation = 0;
  late final AuthService _auth;
  @override
  void initState() {
    super.initState();
    _auth = ref.read(authProvider);
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _auth.cancelLogin();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _schedule();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _timer?.cancel();
    _qr?.close();
    setState(() {
      _loading = true;
      _error = null;
      _qr = null;
    });
    try {
      final q = await ref.read(authProvider).startLogin(_wechat);
      if (!mounted || generation != _generation) {
        q.close();
        return;
      }
      setState(() => _qr = q);
      _schedule();
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openWebLogin() async {
    _generation++;
    _timer?.cancel();
    _auth.cancelLogin();
    setState(() {
      _qr = null;
      _loading = false;
      _error = null;
    });
    final logged = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const WebLoginPage()));
    if (!mounted) return;
    if (logged == true) {
      Navigator.pop(context);
      return;
    }
    await _start();
  }

  void _schedule() {
    _timer?.cancel();
    if (mounted && _foreground && _qr?.active == true) {
      _timer = Timer(const Duration(seconds: 2), _poll);
    }
  }

  Future<void> _poll() async {
    final q = _qr;
    if (_polling || q == null || !q.active || !_foreground) return;
    _polling = true;
    try {
      final done = await ref.read(authProvider).poll(q);
      if (!mounted || !identical(q, _qr)) return;
      if (done) {
        Navigator.pop(context);
        return;
      }
      setState(() => _error = null);
    } catch (e) {
      if (mounted &&
          identical(q, _qr) &&
          !(e is DioException && CancelToken.isCancel(e))) {
        setState(() => _error = errorText(e));
      }
    } finally {
      _polling = false;
      _schedule();
    }
  }

  @override
  Widget build(BuildContext context) => ReviewPageScaffold(
    title: '登录 QQ 音乐',
    bodyBuilder: (context, insets) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        insets.top + 24,
        24,
        24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            children: [
              Text('让你的音乐继续', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text('使用 QQ 音乐对应的 QQ 或微信账号登录', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _openWebLogin,
                icon: const Icon(Icons.language_rounded),
                label: const Text('网页登录 / 导入 Cookie'),
              ),
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('QQ 扫码')),
                  ButtonSegment(value: true, label: Text('微信扫码')),
                ],
                selected: {_wechat},
                onSelectionChanged: (v) {
                  setState(() => _wechat = v.single);
                  _start();
                },
              ),
              const SizedBox(height: 24),
              Container(
                width: 264,
                height: 264,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _qr?.image != null
                    ? Image.memory(
                        _qr!.image!,
                        fit: BoxFit.contain,
                        semanticLabel: _wechat ? '微信登录二维码' : 'QQ 登录二维码',
                        errorBuilder: (_, e, s) => const Center(
                          child: Text(
                            '二维码图片加载失败',
                            style: TextStyle(color: Colors.black),
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.qr_code_2_rounded,
                        size: 120,
                        color: Colors.black,
                      ),
              ),
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                child: Text(
                  _loading ? '正在获取二维码…' : _qr?.status ?? '二维码未加载',
                  textAlign: TextAlign.center,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loading ? null : _start,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新二维码'),
              ),
              const SizedBox(height: 20),
              const Text(
                '也可把二维码截图传到电脑显示，再用手机 QQ 或微信扫码并确认。二维码约 2 分钟后失效。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                '登录仅保存在本机，会员与版权权限由 QQ 音乐决定。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

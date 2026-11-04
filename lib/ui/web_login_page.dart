import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/design_system/components/review_frosted_app_bar.dart';
import '../core/utils/app_dialog.dart';
import '../data/auth_service.dart';
import '../data/models.dart';
import '../data/qq_music_api.dart';
import '../data/web_login.dart';
import '../providers.dart';

class WebLoginPage extends ConsumerStatefulWidget {
  const WebLoginPage({super.key});
  @override
  ConsumerState<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends ConsumerState<WebLoginPage>
    with WidgetsBindingObserver {
  static const _native = MethodChannel('com.green.music/settings');
  late final AuthService _auth;
  late final int _epoch;
  WebViewController? _web;
  WebViewCookieManager? _cookies;
  Timer? _timer;
  bool _dialogOpen = false,
      _checking = false,
      _closing = false,
      _qqPending = false,
      _onMusicSite = false,
      _foreground = true,
      _loading = true;
  String? _error, _lastCookies;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authProvider);
    _epoch = _auth.beginWebLogin();
    _native.setMethodCallHandler((call) async {
      if (call.method != 'onQqWebLoginCallback' || !_qqPending || _closing) {
        return;
      }
      final target = qqWebCallbackUrl(call.arguments as String? ?? '');
      if (target == null) return;
      _qqPending = false;
      try {
        await _web?.loadRequest(target);
      } catch (_) {
        if (mounted && !_closing) {
          setState(() => _error = '返回 QQ 音乐网页失败，可刷新重试或导入 Cookie');
        }
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final web = WebViewController(), cookies = WebViewCookieManager();
      _web = web;
      _cookies = cookies;
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(Colors.white);
      await web.setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
      );
      await web.enableZoom(true);
      if (web.platform is AndroidWebViewController) {
        await (web.platform as AndroidWebViewController).setUseWideViewPort(
          true,
        );
      }
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (request.url == 'about:blank') {
              return NavigationDecision.navigate;
            }
            if (_closing) return NavigationDecision.prevent;
            if (isQqAppLoginUrl(request.url)) {
              unawaited(_openQq(request.url));
              return NavigationDecision.prevent;
            }
            if (!request.isMainFrame &&
                Uri.tryParse(request.url)?.scheme == 'https') {
              return NavigationDecision
                  .navigate; // Official captcha may use a separate HTTPS frame.
            }
            if (isTrustedWebLoginUrl(request.url)) {
              return NavigationDecision.navigate;
            }
            if (mounted && !_closing && request.isMainFrame) {
              setState(() => _error = '暂不支持此跳转，请在 QQ 音乐官网完成登录，或从右上角导入 Cookie');
            }
            return NavigationDecision.prevent;
          },
          onUrlChange: (change) {
            if (change.url != null) _onMusicSite = isMusicWebUrl(change.url!);
          },
          onPageStarted: (url) {
            _onMusicSite = isMusicWebUrl(url);
            if (mounted && !_closing) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted && !_closing) {
              setState(() => _loading = false);
              unawaited(_checkCookies());
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted && !_closing) {
              setState(() {
                _loading = false;
                _error = '网页登录加载失败，可刷新重试或导入电脑端 Cookie';
              });
            }
          },
        ),
      );
      if (cookies.platform is AndroidWebViewCookieManager &&
          web.platform is AndroidWebViewController) {
        await (cookies.platform as AndroidWebViewCookieManager)
            .setAcceptThirdPartyCookies(
              web.platform as AndroidWebViewController,
              true,
            );
      }
      await cookies.clearCookies();
      await web.clearLocalStorage();
      if (!mounted || _closing) return;
      setState(() {});
      await web.loadRequest(musicWebHome);
      _schedule();
    } catch (_) {
      if (mounted && !_closing) {
        setState(() {
          _web = null;
          _loading = false;
          _error = '网页组件暂不可用，仍可使用右上角导入 Cookie';
        });
      }
    }
  }

  Future<void> _openQq(String url) async {
    if (_qqPending || _dialogOpen || _checking || !_foreground || _closing) {
      return;
    }
    try {
      final current = await _web?.currentUrl();
      if (_closing || current == null || !isTrustedWebLoginUrl(current)) return;
      _qqPending = true;
      final opened =
          await _native.invokeMethod<bool>('openQqWebLogin', {'url': url}) ??
          false;
      if (!opened) _qqPending = false;
      if (!opened && mounted && !_closing) {
        setState(() => _error = '未能打开手机 QQ，可在官网选择账号密码登录，或从右上角导入 Cookie');
      }
    } catch (_) {
      _qqPending = false;
      if (mounted && !_closing) {
        setState(() => _error = 'QQ 授权跳转未完成，可在官网继续登录或导入 Cookie');
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_foreground && !_closing) {
      _timer = Timer(const Duration(seconds: 2), () async {
        await _checkCookies();
        if (mounted) _schedule();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _foreground ? _schedule() : _timer?.cancel();
  }

  Future<void> _checkCookies({bool manual = false}) async {
    if (_closing || _checking || _dialogOpen) return;
    if (!_onMusicSite) {
      if (manual) {
        setState(() => _error = '请先在 QQ 音乐官网完成登录；电脑已有登录态可点右上角导入 Cookie');
      }
      return;
    }
    try {
      final raw =
          await _native.invokeMethod<String>('getMusicWebCookies') ?? '';
      if (!mounted ||
          _closing ||
          _checking ||
          _dialogOpen ||
          !_onMusicSite ||
          !manual && raw == _lastCookies) {
        return;
      }
      try {
        musicSessionFromWebCookies(raw);
      } on MusicError {
        if (!manual) return;
        rethrow;
      }
      _lastCookies = raw;
      await _import(raw);
    } catch (e) {
      if (mounted && !_closing) setState(() => _error = errorText(e));
    }
  }

  Future<void> _import(String raw) async {
    if (_closing || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final accepted = await _auth.importWebLoginCookies(raw, epoch: _epoch);
      if (accepted && mounted && !_closing) await _close(success: true);
    } catch (e) {
      if (mounted && !_closing) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _pasteCookie() async {
    _dialogOpen = true;
    String? raw;
    try {
      raw = await showAppDialog<String>(
        context: context,
        builder: (_) => const _CookieImportDialog(),
      );
    } finally {
      _dialogOpen = false;
    }
    if (raw != null && mounted && !_closing) await _import(raw);
  }

  Future<void> _close({bool success = false}) async {
    if (_closing) return;
    _closing = true;
    _native.setMethodCallHandler(null);
    _qqPending = false;
    _timer?.cancel();
    if (!success) _auth.cancelLogin(expectedEpoch: _epoch);
    try {
      await _native.invokeMethod<void>('cancelQqWebLogin');
    } catch (_) {
      /* Web login also supports devices without the native bridge. */
    }
    try {
      await _web?.loadRequest(Uri.parse('about:blank'));
      await _cookies?.clearCookies();
      await _web?.clearLocalStorage();
      await _web?.clearCache();
    } catch (_) {
      /* A missing WebView must not trap manual Cookie login. */
    }
    if (mounted) Navigator.of(context).pop(success);
  }

  @override
  void dispose() {
    if (!_closing) _native.setMethodCallHandler(null);
    _closing = true;
    _timer?.cancel();
    _lastCookies = null;
    _auth.cancelLogin(expectedEpoch: _epoch);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: Scaffold(
      appBar: ReviewFrostedAppBar(
        title: const Text('网页登录'),
        leading: BackButton(onPressed: _close),
        actions: [
          IconButton(
            tooltip: '导入 Cookie',
            onPressed: _checking || _closing ? null : _pasteCookie,
            icon: const Icon(Icons.input_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .28,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('在 QQ 音乐官网点击“登录”。电脑端已登录，可从右上角导入 Cookie。'),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_loading || _checking) const LinearProgressIndicator(),
          Expanded(
            child: _web == null
                ? Center(
                    child: Text(
                      _error == null ? '正在准备网页登录…' : '可导入电脑端 Cookie，或返回使用二维码登录',
                    ),
                  )
                : WebViewWidget(controller: _web!),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _checking || _closing
                        ? null
                        : () async {
                            _qqPending = false;
                            _onMusicSite = false;
                            _lastCookies = null;
                            setState(() => _error = null);
                            try {
                              if (_web == null) {
                                await _initialize();
                                return;
                              }
                              await _cookies?.clearCookies();
                              if (!mounted || _closing) return;
                              await _web?.loadRequest(musicWebHome);
                            } catch (_) {
                              if (mounted && !_closing) {
                                setState(
                                  () => _error = '网页加载失败，仍可导入电脑端 Cookie',
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('刷新'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _checking || _closing
                          ? null
                          : () => _checkCookies(manual: true),
                      child: Text(_checking ? '正在验证…' : '完成登录'),
                    ),
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

class _CookieImportDialog extends StatefulWidget {
  const _CookieImportDialog();
  @override
  State<_CookieImportDialog> createState() => _CookieImportDialogState();
}

class _CookieImportDialogState extends State<_CookieImportDialog> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导入 QQ 音乐 Cookie'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '在电脑 QQ 音乐网页登录后，从开发者工具 Network 中复制 QQ 音乐请求头的 Cookie 值。验证通过后，仅加密保存音乐登录凭据。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            maxLength: 65536,
            decoration: const InputDecoration(
              labelText: 'Cookie',
              counterText: '',
              hintText: '粘贴 QQ 音乐网页 Cookie',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('验证并导入'),
      ),
    ],
  );
}

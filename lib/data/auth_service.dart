// Login flow adapted from Lilt auth*.go (AGPL-3.0).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'models.dart';
import 'qq_music_api.dart';
import 'web_login.dart';

const loginJump = 'https://graph.qq.com/oauth2.0/login_jump';
const wechatAppId = 'wx48db31d50e334801';
String randomHex(int bytes) => List.generate(
  bytes,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
Uri trustedLoginUrl(
  String raw,
  String host,
  String path, {
  String stage = '登录跳转',
}) {
  final u = Uri.tryParse(raw);
  if (u == null ||
      u.scheme != 'https' ||
      u.host != host ||
      u.path != path ||
      u.userInfo.isNotEmpty ||
      u.fragment.isNotEmpty ||
      u.hasPort && u.port != 443) {
    throw MusicError('登录服务返回了不可信的跳转地址（$stage）');
  }
  // Match Lilt's empty-fragment semantics and never forward a fragment to HTTP.
  return u.removeFragment();
}

// Parse the constrained ptuiCB string grammar as data, never execute JavaScript.
List<String> parsePtui(String input) {
  final body = input.trim().replaceFirst(RegExp(r';$'), '');
  if (!body.startsWith('ptuiCB(') || !body.endsWith(')')) {
    throw const MusicError('QQ 扫码状态格式异常');
  }
  var rest = body.substring(7, body.length - 1).trim();
  final pattern = RegExp(
    r"^'((?:[^'\\\r\n]|\\(?:['\\nrt]|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}))*)'\s*",
  );
  final values = <String>[];
  while (rest.isNotEmpty) {
    final m = pattern.firstMatch(rest);
    if (m == null) throw const MusicError('QQ 扫码状态格式异常');
    final value = m[1]!.replaceAllMapped(
      RegExp(r'\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|.)'),
      (e) {
        final s = e[1]!;
        if (s.startsWith('x') || s.startsWith('u')) {
          return String.fromCharCode(int.parse(s.substring(1), radix: 16));
        }
        return switch (s) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => s,
        };
      },
    );
    values.add(value);
    rest = rest.substring(m.end).trim();
    if (rest.isEmpty) break;
    if (!rest.startsWith(',') || values.length >= 7) {
      throw const MusicError('QQ 扫码状态格式异常');
    }
    rest = rest.substring(1).trim();
    if (rest.isEmpty) throw const MusicError('QQ 扫码状态格式异常');
  }
  if (values.length < 6 || values.length > 7) {
    throw const MusicError('QQ 扫码状态格式异常');
  }
  return values;
}

class QrLogin {
  QrLogin(this.wechat);
  final bool wechat;
  final cancel = CancelToken();
  final cookies = <Cookie>[];
  Uint8List? image;
  String key = '', status = '等待扫码';
  Json? device;
  bool scanned = false;
  final expires = DateTime.now().add(const Duration(minutes: 2));
  bool get active => !cancel.isCancelled;
  void close() => cancel.cancel('login closed');
}

class AuthService extends ChangeNotifier {
  AuthService(this.api, {FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();
  final QqMusicApi api;
  final FlutterSecureStorage storage;
  final http = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (s) => s != null && s >= 200 && s < 400,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'User-Agent': 'Mozilla/5.0'},
    ),
  );
  MusicSession? get session => api.session;
  String? restoreError;
  int _epoch = 0;
  Future<void> _writes = Future.value();
  Future<void>? _refreshing;
  QrLogin? _qr;
  CancelToken? _webCancel;

  Future<void> restore() async {
    final epoch = _epoch;
    try {
      final raw = await storage.read(key: 'qqmusic_session');
      if (epoch != _epoch) return;
      if (raw == null) return;
      final s = MusicSession(QqMusicApi.decode(raw));
      if (!s.validIdentity || s.expired && !s.canRefresh) {
        await logout();
        return;
      }
      api.session = s;
      await ensureSession();
    } catch (e) {
      restoreError = errorText(e);
    }
    notifyListeners();
  }

  Future<void> _save(MusicSession? value, int epoch) {
    final next = _writes.then((_) async {
      if (epoch != _epoch) return;
      if (value == null) {
        await storage.delete(key: 'qqmusic_session');
        return;
      }
      await storage.write(key: 'qqmusic_session', value: value.encode());
      if (epoch != _epoch) await storage.delete(key: 'qqmusic_session');
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> logout() async {
    cancelLogin();
    api.session = null;
    restoreError = null;
    notifyListeners();
    await _save(null, _epoch);
  }

  Future<void> replaceFromBackup(MusicSession? value) async {
    if (value != null && !value.validIdentity) {
      throw const MusicError('备份登录凭据无效');
    }
    cancelLogin();
    final epoch = _epoch;
    await _save(value, epoch);
    if (epoch != _epoch) throw const MusicError('账号状态已改变，请重新恢复');
    api.session = value;
    restoreError = null;
    notifyListeners();
  }

  void cancelLogin({int? expectedEpoch}) {
    if (expectedEpoch != null && expectedEpoch != _epoch) return;
    _epoch++;
    _qr?.close();
    _qr = null;
    _webCancel?.cancel('web login closed');
    _webCancel = null;
  }

  int beginWebLogin() {
    cancelLogin();
    _webCancel = CancelToken();
    return _epoch;
  }

  Future<bool> importWebLoginCookies(String raw, {required int epoch}) async {
    final cancel = _webCancel;
    if (epoch != _epoch || cancel == null || cancel.isCancelled) {
      throw const MusicError('本次网页登录已结束');
    }
    final candidate = musicSessionFromWebCookies(raw);
    final profile = await api.rpc(
      'music.UserInfo.userInfoServer',
      'GetLoginUserInfo',
      {},
      comm: candidate.comm,
      headers: {'Cookie': candidate.cookie},
      cancel: cancel,
    );
    final info = obj(profile['info']);
    if (info.isEmpty) throw const MusicError('QQ 音乐尚未验证网页登录，请完成网页授权后重试');
    final verifiedId = text(info, ['musicid', 'uin']);
    if (RegExp(r'^[1-9]\d*$').hasMatch(verifiedId) &&
        verifiedId != candidate.id) {
      throw const MusicError('网页登录的账号不匹配，请刷新网页重试');
    }
    final verified = MusicSession({
      ...candidate.raw,
      'nick': text(info, ['nick', 'nickname']),
      'logo': text(info, ['headurl', 'logo', 'avatarUrl', 'avatar']),
      'encryptUin': text(info, ['encryptUin', 'encrypt_uin']),
    });
    if (epoch != _epoch || cancel.isCancelled) return false;
    await _save(verified, epoch);
    if (epoch != _epoch || cancel.isCancelled) return false;
    api.session = verified;
    restoreError = null;
    notifyListeners();
    return true;
  }

  Future<void> ensureSession() =>
      _refreshing ??= _ensureSession().whenComplete(() => _refreshing = null);
  Future<void> _ensureSession() async {
    final current = session;
    if (current == null) return;
    final epoch = _epoch;
    try {
      var s = current;
      if (s.expired) {
        if (!s.canRefresh) {
          await logout();
          throw const MusicError('登录已过期，请重新扫码');
        }
        s = await _refresh(s);
      }
      Json profile;
      try {
        profile = await api.rpc(
          'music.UserInfo.userInfoServer',
          'GetLoginUserInfo',
          {},
          comm: s.comm,
          headers: {'Cookie': s.cookie},
        );
      } on MusicError catch (e) {
        if (!e.authRejected || !s.canRefresh) rethrow;
        s = await _refresh(s);
        profile = await api.rpc(
          'music.UserInfo.userInfoServer',
          'GetLoginUserInfo',
          {},
          comm: s.comm,
          headers: {'Cookie': s.cookie},
        );
      }
      final info = obj(profile['info']);
      final raw = {...s.raw};
      final name = text(info, ['nick', 'nickname']),
          avatar = text(info, ['headurl', 'logo', 'avatarUrl', 'avatar']);
      if (name.isNotEmpty) raw['nick'] = name;
      if (avatar.isNotEmpty) raw['logo'] = avatar;
      if (epoch != _epoch) return;
      s = MusicSession(raw);
      await _save(s, epoch);
      if (epoch != _epoch) return;
      api.session = s;
      restoreError = null;
      notifyListeners();
    } on MusicError catch (e) {
      if (e.authRejected && epoch == _epoch) await logout();
      rethrow;
    }
  }

  Future<MusicSession> _refresh(MusicSession s) async {
    final device = obj(s.raw['device']);
    final d = device.isEmpty ? await _bootstrapDevice(CancelToken()) : device;
    final next = await _wechatSession(
      {
        'openid': s.raw['openid'] ?? '',
        'refresh_token': s.raw['refresh_token'] ?? '',
        'str_musicid': s.id,
        'musickey': s.key,
        'unionid': s.raw['unionid'] ?? '',
        'refresh_key': s.raw['refresh_key'] ?? '',
        'loginMode': 2,
      },
      d,
      CancelToken(),
      prior: s,
    );
    if (next.id != s.id) throw const MusicError('刷新后的账号不匹配，请重新扫码');
    return MusicSession({
      ...s.raw,
      ...next.raw,
      for (final key in [
        'openid',
        'refresh_token',
        'unionid',
        'refresh_key',
        'nick',
        'logo',
        'encryptUin',
      ])
        if (text(next.raw, [key]).isEmpty && s.raw.containsKey(key))
          key: s.raw[key],
    });
  }

  Future<Response<dynamic>> _request(
    String url, {
    String method = 'GET',
    dynamic data,
    Map<String, String>? headers,
    CancelToken? cancel,
  }) => http.request<dynamic>(
    url,
    data: data,
    cancelToken: cancel,
    options: Options(
      method: method,
      headers: headers,
      responseType: ResponseType.bytes,
    ),
  );
  String _cookie(Response<dynamic> r, String name, String domain) {
    var result = '';
    for (final raw in r.headers['set-cookie'] ?? <String>[]) {
      try {
        final c = Cookie.fromSetCookieValue(raw);
        if (c.name == name &&
            c.domain?.toLowerCase().replaceFirst(RegExp(r'^\.'), '') ==
                domain) {
          result = c.maxAge != null && c.maxAge! <= 0 ? '' : c.value;
        }
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  String _body(Response<dynamic> r, {int limit = 262144}) {
    final bytes = r.data as List<int>;
    if (bytes.length > limit) throw const MusicError('登录服务返回的数据过大');
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const MusicError('登录服务响应编码异常');
    }
  }

  Future<Response<dynamic>> _wechatGet(
    QrLogin q,
    String url, {
    String referer = '',
  }) async {
    final uri = Uri.parse(url);
    final res = await _request(
      url,
      cancel: q.cancel,
      headers: {
        'Referer': referer,
        'Cookie': q.cookies
            .where((c) {
              final domain = (c.domain ?? '').replaceFirst(RegExp(r'^\.'), '');
              return (uri.host == domain || uri.host.endsWith('.$domain')) &&
                  uri.path.startsWith(c.path ?? '/');
            })
            .map((c) => '${c.name}=${c.value}')
            .join('; '),
      },
    );
    for (final raw in res.headers['set-cookie'] ?? <String>[]) {
      try {
        final c = Cookie.fromSetCookieValue(raw);
        c.domain ??= uri.host;
        final domain = c.domain!.replaceFirst(RegExp(r'^\.'), '');
        if (!(domain == 'weixin.qq.com' || domain.endsWith('.weixin.qq.com')) ||
            !(uri.host == domain || uri.host.endsWith('.$domain'))) {
          continue;
        }
        q.cookies.removeWhere(
          (old) => old.name == c.name && old.domain == c.domain,
        );
        if (c.maxAge == null || c.maxAge! > 0) q.cookies.add(c);
      } on FormatException {
        continue;
      }
    }
    if (res.statusCode != 200) throw const MusicError('微信登录服务暂不可用');
    return res;
  }

  Future<QrLogin> startLogin(bool wechat) async {
    cancelLogin();
    final q = QrLogin(wechat);
    _qr = q;
    try {
      if (wechat) {
        q.device = await _bootstrapDevice(q.cancel);
        final url = Uri.https('open.weixin.qq.com', '/connect/qrconnect', {
          'appid': wechatAppId,
          'redirect_uri': 'https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https://y.qq.com/',
          'response_type': 'code',
          'scope': 'snsapi_login',
          'state': 'STATE',
          'href': 'https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect',
        });
        final page = await _wechatGet(q, url.toString());
        final match = RegExp(r'(?:uuid=|/connect/qrcode/)([A-Za-z0-9_-]+)')
            .firstMatch(_body(page));
        if (match == null) throw const MusicError('微信未返回二维码标识');
        q.key = match[1]!;
        final image = await _wechatGet(
          q,
          'https://open.weixin.qq.com/connect/qrcode/${q.key}',
          referer: 'https://open.weixin.qq.com/connect/qrconnect',
        );
        q.image = Uint8List.fromList(image.data as List<int>);
      } else {
        final url = Uri.https('xui.ptlogin2.qq.com', '/ssl/ptqrshow', {
          'appid': '716027609',
          'e': '2',
          'l': 'M',
          's': '3',
          'd': '72',
          'v': '4',
          't': randomHex(8),
          'daid': '383',
          'pt_3rd_aid': '100497308',
          'u1': loginJump,
        });
        final res = await _request(url.toString(), cancel: q.cancel);
        q.key = _cookie(res, 'qrsig', 'ptlogin2.qq.com');
        q.image = Uint8List.fromList(res.data as List<int>);
        if (q.key.isEmpty) throw const MusicError('QQ 未返回二维码签名，请刷新重试');
      }
      final img = q.image!;
      if (img.length > 65536 ||
          img.length < 8 ||
          !(img[0] == 137 && img[1] == 80 || img[0] == 255 && img[1] == 216)) {
        throw const MusicError('登录服务返回的二维码图片无效');
      }
      if (q.cancel.isCancelled) throw q.cancel.cancelError!;
      return q;
    } catch (_) {
      q.close();
      rethrow;
    }
  }

  Future<bool> poll(QrLogin q) async {
    if (!q.active || !identical(q, _qr)) return false;
    if (DateTime.now().isAfter(q.expires)) {
      q.close();
      q.status = '二维码已失效，请刷新';
      return false;
    }
    final epoch = _epoch;
    MusicSession? result;
    if (q.wechat) {
      final uri = Uri.https('lp.open.weixin.qq.com', '/connect/l/qrconnect', {
        'uuid': q.key,
        '_': '${DateTime.now().millisecondsSinceEpoch}',
        if (q.scanned) 'last': '404',
      });
      Response<dynamic> res;
      try {
        res = await _wechatGet(
          q,
          uri.toString(),
          referer: 'https://open.weixin.qq.com/',
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.receiveTimeout) return false;
        rethrow;
      }
      final m = RegExp(
        r"window\.wx_errcode\s*=\s*(\d+)\s*;\s*window\.wx_code\s*=\s*'([^'\r\n]*)'",
      ).firstMatch(_body(res, limit: 16384));
      if (m == null) throw const MusicError('微信扫码状态格式异常');
      switch (m[1]) {
        case '408':
          return false;
        case '404':
          q.scanned = true;
          q.status = '请在微信上确认登录';
          return false;
        case '402':
        case '403':
          q.close();
          q.status = '二维码已失效，请刷新';
          return false;
        case '405':
          if (m[2]!.isEmpty) throw const MusicError('微信未返回授权码');
          try {
            result = await _wechatSession(
              {'code': m[2], 'strAppid': wechatAppId},
              q.device!,
              q.cancel,
            );
          } catch (_) {
            q.close();
            q.status = '本次登录未完成，请刷新二维码或使用网页登录';
            rethrow;
          }
        default:
          throw MusicError('微信扫码失败（服务码 ${m[1]}）');
      }
    } else {
      final uri = Uri.https('xui.ptlogin2.qq.com', '/ssl/ptqrlogin', {
        'u1': loginJump,
        'from_ui': '1',
        'aid': '716027609',
        'daid': '383',
        'pt_3rd_aid': '100497308',
        'ptqrtoken': '${hash33(q.key, 0)}',
      });
      final res = await _request(
        uri.toString(),
        cancel: q.cancel,
        headers: {'Cookie': 'qrsig=${q.key}'},
      );
      final args = parsePtui(_body(res, limit: 16384));
      switch (args[0]) {
        case '66':
          return false;
        case '67':
          q.scanned = true;
          q.status = '请在手机 QQ 上确认登录';
          return false;
        case '65':
          q.close();
          q.status = '二维码已失效，请刷新';
          return false;
        case '0':
          try {
            result = await _exchangeQq(args[2], q.cancel);
          } catch (_) {
            q.close();
            q.status = '本次登录未完成，请刷新二维码或使用网页登录';
            rethrow;
          }
        default:
          throw MusicError('QQ 扫码失败（服务码 ${args[0]}）');
      }
    }
    if (!q.active || epoch != _epoch) return false;
    await _save(result, epoch);
    if (!q.active || epoch != _epoch) return false;
    api.session = result;
    restoreError = null;
    q.close();
    _qr = null;
    notifyListeners();
    return true;
  }

  static MusicSession decodeSession(dynamic input, int expectedType) {
    final body = QqMusicApi.decode(input),
        req = obj(QqMusicApi.decode(input)['req']);
    if (!body.containsKey('code') || !req.containsKey('code')) {
      throw const MusicError('QQ 音乐未返回登录状态');
    }
    if (QqMusicApi.statusCode(body['code']) != 0 ||
        QqMusicApi.statusCode(req['code']) != 0) {
      throw MusicError('QQ 音乐拒绝登录（服务码 ${body['code']}/${req['code']}）');
    }
    final raw = obj(req['data']);
    if (expectedType == 1 && integer(raw['loginType']) == 0) {
      raw['loginType'] = 1;
    }
    final s = MusicSession(raw);
    if (!s.validIdentity || s.loginType != expectedType || s.expired) {
      throw const MusicError('QQ 音乐返回了无效或过期的登录凭据');
    }
    return s;
  }

  Future<MusicSession> _exchangeQq(String redirect, CancelToken cancel) async {
    final trusted = trustedLoginUrl(
      redirect,
      'ssl.ptlogin2.graph.qq.com',
      '/check_sig',
      stage: 'QQ 扫码确认',
    );
    var res = await _request(trusted.toString(), cancel: cancel);
    if (res.statusCode != 302) throw const MusicError('QQ 授权校验未跳转');
    final jump = trustedLoginUrl(
      res.headers.value('location') ?? '',
      'graph.qq.com',
      '/oauth2.0/login_jump',
      stage: 'QQ 授权校验',
    );
    final cookies = <String>[];
    var skey = '';
    for (final name in ['p_uin', 'p_skey', 'pt_oauth_token']) {
      final value = _cookie(res, name, 'graph.qq.com');
      if (value.isEmpty) throw const MusicError('QQ 授权凭据不完整');
      cookies.add('$name=$value');
      if (name == 'p_skey') skey = value;
    }
    res = await _request(jump.toString(), cancel: cancel);
    if (res.statusCode != 200) throw const MusicError('QQ 授权跳转失败');
    final state = randomHex(16), id = randomHex(16);
    final form = {
      'response_type': 'code',
      'client_id': '100497308',
      'redirect_uri': 'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/',
      'scope': 'get_user_info,get_app_friends',
      'state': state,
      'switch': '',
      'from_ptlogin': '1',
      'src': '1',
      'update_auth': '1',
      'openapi': '1010_1030',
      'g_tk': '${hash33(skey)}',
      'auth_time': '${DateTime.now().millisecondsSinceEpoch}',
      'ui':
          '${id.substring(0, 8)}-${id.substring(8, 12)}-${id.substring(12, 16)}-${id.substring(16, 20)}-${id.substring(20)}',
    };
    res = await _request(
      'https://graph.qq.com/oauth2.0/authorize',
      method: 'POST',
      data: Uri(queryParameters: form).query,
      cancel: cancel,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': cookies.join('; '),
      },
    );
    if (res.statusCode != 302) throw const MusicError('QQ 未确认授权');
    final location = res.headers.value('location') ?? '';
    final destination = Uri.tryParse(location);
    if (destination?.host == 'graph.qq.com' &&
        destination?.path == '/oauth2.0/show') {
      trustedLoginUrl(
        location,
        'graph.qq.com',
        '/oauth2.0/show',
        stage: 'QQ 授权回调',
      );
      throw const MusicError('QQ 要求继续确认网页授权，请点击“网页登录”完成登录');
    }
    final back = trustedLoginUrl(
      location,
      'y.qq.com',
      '/portal/wx_redirect.html',
      stage: 'QQ 授权回调',
    );
    final codes = back.queryParametersAll['code'],
        states = back.queryParametersAll['state'];
    if (codes?.length != 1 ||
        states?.length != 1 ||
        states!.single != state ||
        !RegExp(r'^[A-F0-9]{32}$').hasMatch(codes!.single)) {
      throw const MusicError('QQ 授权状态或授权码不匹配');
    }
    res = await _request(
      musicuUrl,
      method: 'POST',
      cancel: cancel,
      data: jsonEncode({
        'comm': {'g_tk': 5381, 'platform': 'yqq', 'ct': 24, 'cv': 0},
        'req': {
          'module': 'QQConnectLogin.LoginServer',
          'method': 'QQLogin',
          'param': {'code': codes.single},
        },
      }),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    );
    return decodeSession(_body(res, limit: 16384), 2);
  }

  Future<MusicSession> _wechatSession(
    Json param,
    Json device,
    CancelToken cancel, {
    MusicSession? prior,
  }) async {
    final res = await _request(
      musicuUrl,
      method: 'POST',
      cancel: cancel,
      data: jsonEncode({
        'comm': {
          ...deviceComm(device),
          'tmeLoginType': 1,
          if (prior != null) ...{'qq': prior.id, 'authst': prior.key},
        },
        'req': {
          'module': 'music.login.LoginServer',
          'method': 'Login',
          'param': param,
        },
      }),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': qqUserAgent,
        'Referer': 'https://y.qq.com/',
        if (prior != null) 'Cookie': prior.cookie,
      },
    );
    final session = decodeSession(_body(res, limit: 16384), 1);
    return MusicSession({...session.raw, 'device': device});
  }

  Future<Json> _bootstrapDevice(CancelToken cancel) async {
    final imei = randomDigits(14);
    var sum = 0;
    for (var i = 0; i < imei.length; i++) {
      var n = int.parse(imei[i]);
      if (i.isOdd) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
    }
    final d = <String, dynamic>{
      'androidId': randomHex(8),
      'openUdid': randomHex(16),
      'imei': '$imei${(10 - sum % 10) % 10}',
    };
    var now = DateTime.now().toUtc();
    for (var attempt = 0; attempt < 2; attempt++) {
      final envelope = qimeiEnvelope(d, now);
      final res = await _request(
        'https://api.tencentmusic.com/tme/trpc/proxy',
        method: 'POST',
        data: envelope.$1,
        headers: envelope.$2,
        cancel: cancel,
      );
      Json embedded(dynamic value) =>
          value is String ? QqMusicApi.decode(value) : obj(value);
      final data = embedded(
        embedded(QqMusicApi.decode(_body(res, limit: 65536))['data'])['data'],
      );
      d['qimei'] = text(data, ['q16']);
      d['qimei36'] = text(data, ['q36']);
      if (d['qimei'] != '' && d['qimei36'] != '') break;
      final serverDate = res.headers.value('date');
      DateTime? serverTime;
      try {
        if (serverDate != null) serverTime = HttpDate.parse(serverDate);
      } on FormatException {
        serverTime = null;
      }
      if (attempt == 0 &&
          serverTime != null &&
          now.difference(serverTime).abs() > const Duration(minutes: 1)) {
        now = serverTime.toUtc();
        continue;
      }
      throw const MusicError('微信登录设备初始化未返回 QIMEI，请稍后重试');
    }
    final data = await api.rpc(
      'music.getSession.session',
      'GetSession',
      {'uid': '', 'vkey': 0, 'caller': 0},
      comm: deviceComm(d),
      headers: {'Cookie': ''},
      cancel: cancel,
    );
    final session = obj(data['session']);
    d['uid'] = '${session['uid'] ?? ''}';
    d['sid'] = '${session['sid'] ?? ''}';
    if (d['uid'] == '' || d['sid'] == '') throw const MusicError('微信登录未返回设备会话');
    return d;
  }
}

(String, Map<String, String>) qimeiEnvelope(Json d, DateTime now) {
  const appKey = '0AND0HD6FE4HY80F';
  const modulus =
      'c4231830a2eb5fc2827170641e79d80fec51bda9a22e4b4ab37d1f205a4ae44d928cda25879f66a3429051663312a127faf8a246bdaaf63918417e90d7c95b5908aa6a2d0f852e4a6770294a548ac1c2fe8f1f252fb826f4ac86ab9a00e7ce47d002a56e7c4b51eb889acc60ca6adbc9f72e81f4d31b1dd7464805264530ab1d';
  final key = randomHex(8),
      nonce = randomHex(8),
      first = randomDigits(6),
      second = randomDigits(9);
  final dated = {1, 2, 13, 14, 17, 18, 21, 22, 25, 26, 29, 30, 33, 34, 37, 38};
  final date = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final beacon = StringBuffer();
  for (var i = 1; i <= 40; i++) {
    final value = i == 3
        ? '0000000000000000'
        : i == 4
        ? key.replaceAll('0', '1')
        : dated.contains(i)
        ? '$date-01$first.$second'
        : randomDigits(4);
    beacon.write('k$i:$value;');
  }
  String time(DateTime v) =>
      '${v.year}-${v.month.toString().padLeft(2, '0')}-${v.day.toString().padLeft(2, '0')} ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}:${v.second.toString().padLeft(2, '0')}';
  final reserved = jsonEncode({
    'harmony': '0',
    'clone': '0',
    'containe': '',
    'oz': 'UhYmelwouA+V2nPWbOvLTgN2/m8jwGB+yUB5v9tysQg=',
    'oo': 'Xecjt+9S1+f8Pz2VLSxgpw==',
    'kelong': '0',
    'uptimes': time(now.subtract(const Duration(hours: 1))),
    'multiUser': '0',
    'bod': 'Xiaomi',
    'dv': 'sagit',
    'firstLevel': '',
    'manufact': 'Xiaomi',
    'name': 'MI 6',
    'host': 'se.infra',
    'kernel': 'Linux 5.4.0-54-generic (android-build@google.com)',
  });
  final payload = utf8.encode(
    jsonEncode({
      'androidId': d['androidId'],
      'platformId': 1,
      'appKey': appKey,
      'appVersion': '14.9.0.8',
      'beaconIdSrc': beacon.toString(),
      'brand': 'Xiaomi',
      'channelId': '10003505',
      'cid': '',
      'imei': d['imei'],
      'imsi': '',
      'mac': '',
      'model': 'MI 6',
      'networkType': 'unknown',
      'oaid': '',
      'osVersion': 'Android 10,level 29',
      'qimei': '',
      'qimei36': '',
      'sdkVersion': '1.2.13.6',
      'targetSdkVersion': '33',
      'audit': '',
      'userId': '{}',
      'packageId': 'com.tencent.qqmusic',
      'deviceType': 'Phone',
      'sdkName': '',
      'reserved': reserved,
    }),
  );
  final random = FortunaRandom()
    ..seed(
      KeyParameter(
        Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );
  final rsa = PKCS1Encoding(RSAEngine())
    ..init(
      true,
      ParametersWithRandom(
        PublicKeyParameter<RSAPublicKey>(
          RSAPublicKey(BigInt.parse(modulus, radix: 16), BigInt.from(65537)),
        ),
        random,
      ),
    );
  final wrapped = base64Encode(
    rsa.process(Uint8List.fromList(utf8.encode(key))),
  );
  final keyBytes = Uint8List.fromList(utf8.encode(key));
  final aes = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(keyBytes), keyBytes),
        null,
      ),
    );
  final params = base64Encode(aes.process(Uint8List.fromList(payload)));
  final seconds = now.millisecondsSinceEpoch ~/ 1000,
      ts = '$seconds',
      extra = jsonEncode({'appKey': appKey});
  String digest(String value) => md5.convert(utf8.encode(value)).toString();
  final body = jsonEncode({
    'app': 0,
    'os': 1,
    'qimeiParams': {
      'key': wrapped,
      'params': params,
      'time': ts,
      'nonce': nonce,
      'sign': digest(
        '$wrapped$params${seconds * 1000}${nonce}ZdJqM15EeO2zWc08$extra',
      ),
      'extra': extra,
    },
  });
  return (
    body,
    {
      'Method': 'GetQimei',
      'Service': 'trpc.tme_datasvr.qimeiproxy.QimeiProxy',
      'Appid': 'qimei_qq_android',
      'Sign': digest('qimei_qq_androidpzAuCmaFAaFaHrdakPjLIEqKrGnSOOvH$ts'),
      'Timestamp': ts,
      'Content-Type': 'application/json',
      'User-Agent': 'QQMusic',
    },
  );
}

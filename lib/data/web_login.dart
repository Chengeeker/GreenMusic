import 'models.dart';

final musicWebHome = Uri.https('y.qq.com', '/');
const qqWebCallbackPrefix = 'com.green.music.login://qq/';

Uri? qqWebCallbackUrl(String raw) {
  if (!raw.startsWith(qqWebCallbackPrefix)) return null;
  try {
    final value = raw.substring(qqWebCallbackPrefix.length);
    final target = value.startsWith('https://')
        ? value
        : Uri.decodeComponent(value);
    if (RegExp(r'[\r\n]|%0[ad]', caseSensitive: false).hasMatch(target) ||
        !isTrustedWebLoginUrl(target)) {
      return null;
    }
    return Uri.parse(target);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

bool isTrustedWebLoginUrl(String raw) {
  final uri = Uri.tryParse(raw);
  return uri != null &&
      uri.scheme == 'https' &&
      (uri.host == 'qq.com' || uri.host.endsWith('.qq.com')) &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);
}

bool isMusicWebUrl(String raw) {
  final uri = Uri.tryParse(raw);
  return isTrustedWebLoginUrl(raw) &&
      uri != null &&
      (uri.host == 'y.qq.com' || uri.host.endsWith('.y.qq.com'));
}

bool isQqAppLoginUrl(String raw) {
  final uri = Uri.tryParse(raw);
  return uri != null &&
      ['mqqapi', 'wtloginmqq'].contains(uri.scheme) &&
      uri.host == 'ptlogin' &&
      uri.path == '/qlogin' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      uri.fragment.isEmpty;
}

MusicSession musicSessionFromWebCookies(String raw) {
  if (raw.length > 65536 || RegExp(r'[\r\n]').hasMatch(raw)) {
    throw const MusicError('网页登录凭据格式无效');
  }
  const names = {
    'uin',
    'qqmusic_uin',
    'wxuin',
    'qqmusic_key',
    'qm_keyst',
    'wxqqmusic_key',
    'login_type',
    'wxopenid',
  };
  final cookies = <String, String>{};
  final header = raw.trim().replaceFirst(
    RegExp(r'^cookie:\s*', caseSensitive: false),
    '',
  );
  for (final part in header.split(';')) {
    final separator = part.indexOf('=');
    if (separator < 1) continue;
    final name = part.substring(0, separator).trim();
    if (!names.contains(name)) continue;
    String value;
    try {
      value = Uri.decodeComponent(part.substring(separator + 1).trim());
    } on FormatException {
      throw const MusicError('网页登录凭据编码无效');
    }
    if (value.isEmpty) continue;
    if (cookies.containsKey(name) && cookies[name] != value) {
      throw const MusicError('网页登录凭据冲突，请刷新网页登录');
    }
    cookies[name] = value;
  }
  if (cookies['login_type'] != null &&
      !['1', '2'].contains(cookies['login_type'])) {
    throw const MusicError('Cookie 未标记为已登录，请从电脑端已登录的请求重新复制');
  }
  final wechat =
      cookies['login_type'] == '2' ||
      cookies['login_type'] == null && (cookies['wxopenid'] ?? '').isNotEmpty;
  var id =
      (wechat ? cookies['wxuin'] : cookies['uin']) ??
      cookies['qqmusic_uin'] ??
      '';
  id = id.replaceFirst(RegExp(r'^o'), '');
  if (RegExp(r'^\d+$').hasMatch(id)) id = BigInt.parse(id).toString();
  final key =
      (wechat ? cookies['wxqqmusic_key'] : cookies['qqmusic_key']) ??
      cookies['qm_keyst'] ??
      '';
  final session = MusicSession({
    'musicid': id,
    'musickey': key,
    'loginType': wechat ? 1 : 2,
  });
  if (!session.validIdentity) {
    throw const MusicError('尚未取得 QQ 音乐登录态，请先在网页中完成登录授权');
  }
  return session;
}

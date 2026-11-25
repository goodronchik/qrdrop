import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class SharedFileItem {
  final String name;
  final String path;
  final int size;
  final DateTime modified;
  final bool isReceived;

  SharedFileItem({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
    required this.isReceived,
  });

  Map<String, dynamic> toJson(bool readonly) => {
        'name': name,
        'size': size,
        'size_human': formatSize(size),
        'mtime': _fmtTime(modified),
        'deletable': !readonly,
      };
}

class ClipItem {
  final String id;
  final String text;
  final String sender;
  final String time;

  ClipItem({
    required this.id,
    required this.text,
    required this.sender,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'sender': sender,
        'time': time,
      };
}

String formatSize(int bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  double val = bytes.toDouble();
  for (final u in units) {
    if (val < 1024 || u == units.last) {
      return u == 'Б' ? '${val.toInt()} $u' : '${val.toStringAsFixed(1)} $u';
    }
    val /= 1024;
  }
  return '$bytes Б';
}

String _fmtTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
}

String _fmtClock(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String sanitizeFilename(String raw) {
  var name = raw.replaceAll('\\', '/').split('/').last.trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
  name = name.replaceAll(RegExp(r'^\.+|\.+$'), '');
  return name.isEmpty ? 'file' : name;
}

class QrDropServer extends ChangeNotifier {
  HttpServer? _server;
  bool _running = false;
  int _port = 8080;
  bool _requireAuth = true;
  bool _readonly = false;
  String _token = '';
  String _pin = '';
  List<String> _ips = [];
  String _activeIp = '127.0.0.1';
  Directory? _receiveDir;
  String? _lastError;

  final Map<String, File> _pinnedFiles = {};
  final List<ClipItem> _clips = [];

  bool get isRunning => _running;
  int get port => _port;
  bool get requireAuth => _requireAuth;
  bool get readonly => _readonly;
  String get pin => _requireAuth ? _pin : '';
  List<String> get ips => List.unmodifiable(_ips);
  String get activeIp => _activeIp;
  String get receiveDirPath => _receiveDir?.path ?? '';
  String? get lastError => _lastError;
  List<ClipItem> get clips => List.unmodifiable(_clips);

  String get shareUrl {
    final base = 'http://$_activeIp:$_port/';
    return _requireAuth && _token.isNotEmpty ? '$base?t=$_token' : base;
  }

  Future<void> initAndStart() async {
    _receiveDir = await _resolveReceiveDir();
    await refreshIps();
    await start();
  }

  Future<Directory> _resolveReceiveDir() async {
    Directory? base;
    try {
      if (Platform.isAndroid) {
        base = await getExternalStorageDirectory();
      } else {
        base = await getDownloadsDirectory();
      }
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}QRDrop');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> refreshIps() async {
    final found = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) {
            if (!found.contains(ip)) found.add(ip);
          }
        }
      }
    } catch (_) {}

    // Приоритет домашним Wi-Fi сетям 192.168.x.x и 10.x.x.x
    found.sort((a, b) {
      int score(String ip) {
        if (ip.startsWith('192.168.')) return 0;
        if (ip.startsWith('10.')) return 1;
        if (ip.startsWith('172.')) return 2;
        return 3;
      }

      return score(a).compareTo(score(b));
    });

    if (found.isEmpty) found.add('127.0.0.1');
    _ips = found;
    if (!_ips.contains(_activeIp)) {
      _activeIp = _ips.first;
    }
    notifyListeners();
  }

  void setActiveIp(String ip) {
    if (_ips.contains(ip)) {
      _activeIp = ip;
      notifyListeners();
    }
  }

  void setReadonly(bool value) {
    _readonly = value;
    notifyListeners();
  }

  void setRequireAuth(bool value) {
    _requireAuth = value;
    if (_requireAuth && _token.isEmpty) {
      _generateSecrets();
    }
    notifyListeners();
  }

  void _generateSecrets() {
    final rnd = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    _token = List.generate(10, (_) => chars[rnd.nextInt(chars.length)]).join();
    _pin = rnd.nextInt(10000).toString().padLeft(4, '0');
  }

  Future<void> start({int preferredPort = 8080}) async {
    if (_running) return;
    _lastError = null;
    _receiveDir ??= await _resolveReceiveDir();
    if (_ips.isEmpty) await refreshIps();
    _generateSecrets();

    HttpServer? bound;
    for (int p = preferredPort; p < preferredPort + 25; p++) {
      try {
        bound = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: true);
        _port = p;
        break;
      } catch (_) {}
    }

    if (bound == null) {
      _lastError = 'Не удалось открыть порт (проверьте брандмауэр)';
      notifyListeners();
      return;
    }

    _server = bound;
    _running = true;
    notifyListeners();

    bound.listen(_handleRequest, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _running = false;
    notifyListeners();
  }

  void addFiles(List<String> paths) {
    for (final p in paths) {
      final f = File(p);
      if (!f.existsSync()) continue;
      var name = sanitizeFilename(p);
      if (_pinnedFiles.containsKey(name) && _pinnedFiles[name]!.path != f.path) {
        final dot = name.lastIndexOf('.');
        final stem = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        int i = 1;
        while (_pinnedFiles.containsKey('$stem ($i)$ext')) {
          i++;
        }
        name = '$stem ($i)$ext';
      }
      _pinnedFiles[name] = f;
    }
    notifyListeners();
  }

  Future<void> removeFile(String name) async {
    if (_pinnedFiles.containsKey(name)) {
      _pinnedFiles.remove(name);
    } else if (_receiveDir != null) {
      final clean = sanitizeFilename(name);
      final target = File('${_receiveDir!.path}${Platform.pathSeparator}$clean');
      if (clean == name && await target.exists()) {
        await target.delete();
      }
    }
    notifyListeners();
  }

  void addClip(String text, {String sender = 'Это устройство'}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final rnd = Random.secure();
    final id = rnd.nextInt(1 << 30).toRadixString(16);
    _clips.insert(
      0,
      ClipItem(
        id: id,
        text: trimmed.length > 10000 ? trimmed.substring(0, 10000) : trimmed,
        sender: sender,
        time: _fmtClock(DateTime.now()),
      ),
    );
    if (_clips.length > 30) _clips.removeRange(30, _clips.length);
    notifyListeners();
  }

  List<SharedFileItem> listFiles() {
    final map = <String, SharedFileItem>{};

    if (_receiveDir != null && _receiveDir!.existsSync()) {
      for (final ent in _receiveDir!.listSync()) {
        if (ent is File) {
          final name = ent.uri.pathSegments.isNotEmpty
              ? Uri.decodeComponent(ent.uri.pathSegments.last)
              : sanitizeFilename(ent.path);
          if (name.startsWith('.') || name.endsWith('.part')) continue;
          try {
            final st = ent.statSync();
            map[name] = SharedFileItem(
              name: name,
              path: ent.path,
              size: st.size,
              modified: st.modified,
              isReceived: true,
            );
          } catch (_) {}
        }
      }
    }

    for (final entry in _pinnedFiles.entries) {
      if (!entry.value.existsSync()) continue;
      if (map.containsKey(entry.key)) continue;
      try {
        final st = entry.value.statSync();
        map[entry.key] = SharedFileItem(
          name: entry.key,
          path: entry.value.path,
          size: st.size,
          modified: st.modified,
          isReceived: false,
        );
      } catch (_) {}
    }

    final list = map.values.toList();
    list.sort((a, b) => b.modified.compareTo(a.modified));
    return list;
  }

  File? _resolveFile(String name) {
    final clean = sanitizeFilename(name);
    if (clean != name) return null;
    if (_receiveDir != null) {
      final f = File('${_receiveDir!.path}${Platform.pathSeparator}$clean');
      if (f.existsSync()) return f;
    }
    final pinned = _pinnedFiles[clean];
    if (pinned != null && pinned.existsSync()) return pinned;
    return null;
  }

  File _uniqueReceiveFile(String rawName) {
    final base = sanitizeFilename(rawName);
    final dir = _receiveDir!.path;
    final sep = Platform.pathSeparator;
    var candidate = File('$dir$sep$base');
    if (!candidate.existsSync()) return candidate;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    int i = 1;
    while (true) {
      candidate = File('$dir$sep$stem ($i)$ext');
      if (!candidate.existsSync()) return candidate;
      i++;
    }
  }

  bool _isAuthorized(HttpRequest req) {
    if (!_requireAuth) return true;
    for (final c in req.cookies) {
      if (c.name == 'qrdrop_token' && c.value == _token) return true;
    }
    return false;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      final qToken = req.uri.queryParameters['t'];

      // Вход по токену из QR-кода -> ставим cookie и редиректим на /
      if (_requireAuth && qToken != null && qToken == _token) {
        req.response.cookies.add(
          Cookie('qrdrop_token', _token)
            ..path = '/'
            ..httpOnly = true,
        );
        req.response.statusCode = HttpStatus.found;
        req.response.headers.set(HttpHeaders.locationHeader, '/');
        await req.response.close();
        return;
      }

      // Вход по PIN-коду
      if (req.method == 'POST' && path == '/login') {
        final body = await utf8.decoder.bind(req).join();
        final params = Uri.splitQueryString(body);
        if ((params['pin'] ?? '').trim() == _pin) {
          req.response.cookies.add(
            Cookie('qrdrop_token', _token)
              ..path = '/'
              ..httpOnly = true,
          );
          req.response.statusCode = HttpStatus.found;
          req.response.headers.set(HttpHeaders.locationHeader, '/');
          await req.response.close();
        } else {
          await _sendHtml(
            req,
            _loginHtml.replaceAll('{error}', '<div class="err">Неверный PIN-код</div>'),
            status: HttpStatus.unauthorized,
          );
        }
        return;
      }

      if (!_isAuthorized(req)) {
        if (path.startsWith('/api/')) {
          await _sendJson(req, {'error': 'Требуется авторизация'}, status: HttpStatus.unauthorized);
        } else {
          await _sendHtml(req, _loginHtml.replaceAll('{error}', ''));
        }
        return;
      }

      if (req.method == 'GET' && path == '/') {
        await _sendHtml(req, _webAppHtml);
        return;
      }

      if (req.method == 'GET' && path == '/api/info') {
        await _sendJson(req, {
          'host': '${Platform.operatingSystem.toUpperCase()} (${Platform.localHostname})',
          'readonly': _readonly,
          'url': shareUrl,
        });
        return;
      }

      if (req.method == 'GET' && path == '/api/files') {
        final files = listFiles().map((f) => f.toJson(_readonly)).toList();
        await _sendJson(req, {'files': files});
        return;
      }

      if (req.method == 'GET' && path == '/api/clips') {
        await _sendJson(req, {'clips': _clips.map((c) => c.toJson()).toList()});
        return;
      }

      if (req.method == 'POST' && path == '/api/clips') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final text = (data['text'] ?? '').toString().trim();
        if (text.isEmpty) {
          await _sendJson(req, {'error': 'Пустой текст'}, status: HttpStatus.badRequest);
          return;
        }
        final sender = req.connectionInfo?.remoteAddress.address ?? 'Устройство';
        addClip(text, sender: sender);
        await _sendJson(req, {'ok': true}, status: HttpStatus.created);
        return;
      }

      if (req.method == 'POST' && path == '/api/upload') {
        if (_readonly) {
          await _sendJson(req, {'error': 'Режим только для чтения'}, status: HttpStatus.forbidden);
          return;
        }
        final rawName = req.uri.queryParameters['name'] ?? 'upload.bin';
        final target = _uniqueReceiveFile(rawName);
        final tmp = File('${target.path}.part');
        final sink = tmp.openWrite();
        try {
          await sink.addStream(req);
          await sink.close();
          await tmp.rename(target.path);
          notifyListeners();
          await _sendJson(req, {'saved': sanitizeFilename(target.path)}, status: HttpStatus.created);
        } catch (e) {
          if (await tmp.exists()) await tmp.delete();
          await _sendJson(req, {'error': e.toString()}, status: HttpStatus.internalServerError);
        }
        return;
      }

      if (req.method == 'GET' && path.startsWith('/download/')) {
        final name = Uri.decodeComponent(path.substring('/download/'.length));
        final file = _resolveFile(name);
        if (file == null) {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write('Файл не найден');
          await req.response.close();
          return;
        }
        final len = await file.length();
        final enc = Uri.encodeComponent(name);
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
        req.response.headers.set('Content-Disposition', "attachment; filename*=UTF-8''$enc");
        req.response.headers.set(HttpHeaders.contentLengthHeader, len.toString());
        await req.response.addStream(file.openRead());
        await req.response.close();
        return;
      }

      if (req.method == 'DELETE' && path.startsWith('/api/files/')) {
        if (_readonly) {
          await _sendJson(req, {'error': 'Режим только для чтения'}, status: HttpStatus.forbidden);
          return;
        }
        final name = Uri.decodeComponent(path.substring('/api/files/'.length));
        await removeFile(name);
        await _sendJson(req, {'deleted': name});
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      req.response.write('Not Found');
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _sendHtml(HttpRequest req, String html, {int status = HttpStatus.ok}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.html;
    req.response.write(html);
    await req.response.close();
  }

  Future<void> _sendJson(HttpRequest req, Object data, {int status = HttpStatus.ok}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }
}

const String _loginHtml = '''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>QRDrop — Вход</title>
<style>
  :root { color-scheme: dark light; --bg:#0f172a; --card:#1e293b; --text:#f8fafc; --muted:#94a3b8; --accent:#3b82f6; --border:#334155; }
  @media (prefers-color-scheme: light) { :root { --bg:#f1f5f9; --card:#fff; --text:#0f172a; --muted:#64748b; --accent:#2563eb; --border:#e2e8f0; } }
  body { margin:0; font-family:system-ui,sans-serif; background:var(--bg); color:var(--text); min-height:100vh; display:grid; place-items:center; padding:20px; }
  .box { width:100%; max-width:350px; background:var(--card); border:1px solid var(--border); border-radius:20px; padding:26px; text-align:center; }
  input { width:100%; box-sizing:border-box; padding:14px; font-size:24px; letter-spacing:8px; text-align:center; border-radius:12px; border:1px solid var(--border); background:var(--bg); color:var(--text); margin:14px 0; }
  button { width:100%; padding:13px; font-size:16px; font-weight:600; border:0; border-radius:12px; background:var(--accent); color:#fff; cursor:pointer; }
  .err { color:#ef4444; font-size:14px; }
</style>
</head>
<body>
  <form class="box" method="POST" action="/login">
    <h2>QRDrop</h2>
    <p style="color:var(--muted);font-size:14px">Введите 4-значный PIN-код из приложения</p>
    {error}
    <input name="pin" type="tel" inputmode="numeric" maxlength="4" placeholder="••••" autofocus required>
    <button type="submit">Войти</button>
  </form>
</body>
</html>''';

const String _webAppHtml = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>QRDrop — Обмен файлами</title>
<style>
  :root { color-scheme: dark light; --bg:#0b1120; --s:#131c31; --s2:#1c2842; --t:#f1f5f9; --m:#94a3b8; --a:#3b82f6; --b:#263450; --d:#ef4444; }
  @media (prefers-color-scheme: light) { :root { --bg:#f1f5f9; --s:#fff; --s2:#f8fafc; --t:#0f172a; --m:#64748b; --a:#2563eb; --b:#e2e8f0; --d:#dc2626; } }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--t); }
  .wrap { max-width:780px; margin:0 auto; padding:18px 14px 48px; }
  h1 { margin:0 0 4px; font-size:22px; }
  .sub { color:var(--m); font-size:13px; margin-bottom:16px; }
  .card { background:var(--s); border:1px solid var(--b); border-radius:16px; padding:16px; margin-bottom:16px; }
  .dz { border:2px dashed var(--b); border-radius:14px; padding:24px 12px; text-align:center; background:var(--s2); cursor:pointer; margin-bottom:12px; }
  .dz.drag { border-color:var(--a); }
  .btn { display:inline-flex; align-items:center; gap:6px; padding:8px 14px; border-radius:10px; border:1px solid var(--b); background:var(--s2); color:var(--t); font-weight:600; font-size:14px; text-decoration:none; cursor:pointer; }
  .btn-p { background:var(--a); border-color:var(--a); color:#fff; }
  .item { display:flex; align-items:center; justify-content:space-between; gap:10px; padding:10px 12px; border-radius:12px; background:var(--s2); border:1px solid var(--b); margin-top:8px; }
  .name { font-weight:600; font-size:14px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .meta { font-size:12px; color:var(--m); }
  .bar { height:8px; border-radius:99px; background:var(--s2); overflow:hidden; margin:8px 0 12px; display:none; }
  .bar>div { height:100%; width:0; background:var(--a); }
  textarea { width:100%; min-height:54px; padding:10px; border-radius:10px; border:1px solid var(--b); background:var(--s2); color:var(--t); font:inherit; margin-bottom:8px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>QRDrop</h1>
  <div class="sub" id="hostInfo">Подключено по локальной сети</div>

  <div class="card">
    <div id="upBox">
      <div class="dz" id="dz"><strong>Нажмите или перетащите файлы сюда</strong><div class="meta">Отправка на устройство</div><input type="file" id="fi" multiple style="display:none"></div>
      <div class="bar" id="bar"><div id="barIn"></div></div>
    </div>
    <div id="files">Загрузка...</div>
  </div>

  <div class="card">
    <h3 style="margin:0 0 10px">Текст и ссылки</h3>
    <textarea id="clipIn" placeholder="Вставьте текст или ссылку..."></textarea>
    <button class="btn btn-p" onclick="sendClip()">Отправить</button>
    <div id="clips"></div>
  </div>
</div>
<script>
const esc = s => String(s).replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
async function load() {
  const info = await (await fetch('/api/info')).json();
  document.getElementById('hostInfo').textContent = 'Хост: ' + info.host;
  document.getElementById('upBox').style.display = info.readonly ? 'none' : 'block';
  const fdata = await (await fetch('/api/files')).json();
  document.getElementById('files').innerHTML = fdata.files.length ? fdata.files.map(f =>
    `<div class="item"><div style="min-width:0;flex:1"><div class="name">${esc(f.name)}</div><div class="meta">${esc(f.size_human)} • ${esc(f.mtime)}</div></div>` +
    `<a class="btn btn-p" href="/download/${encodeURIComponent(f.name)}" download>Скачать</a></div>`
  ).join('') : '<div class="meta" style="text-align:center;padding:16px">Файлов пока нет</div>';
  const cdata = await (await fetch('/api/clips')).json();
  document.getElementById('clips').innerHTML = cdata.clips.map(c =>
    `<div class="item"><div style="white-space:pre-wrap;word-break:break-word;flex:1">${esc(c.text)}<div class="meta">${esc(c.sender)} • ${esc(c.time)}</div></div>` +
    `<button class="btn" data-t="${esc(c.text)}" onclick="navigator.clipboard.writeText(this.dataset.t)">Копировать</button></div>`
  ).join('');
}
async function sendClip() {
  const el = document.getElementById('clipIn');
  if (!el.value.trim()) return;
  await fetch('/api/clips', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({text:el.value}) });
  el.value = ''; load();
}
function upload(files) {
  const arr = Array.from(files); let i = 0;
  const bar = document.getElementById('bar'), barIn = document.getElementById('barIn');
  bar.style.display = 'block';
  (function next() {
    if (i >= arr.length) { bar.style.display = 'none'; load(); return; }
    const f = arr[i++], xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload?name=' + encodeURIComponent(f.name));
    xhr.upload.onprogress = e => { if (e.lengthComputable) barIn.style.width = (e.loaded/e.total*100) + '%'; };
    xhr.onload = next; xhr.send(f);
  })();
}
const dz = document.getElementById('dz'), fi = document.getElementById('fi');
dz.onclick = () => fi.click();
fi.onchange = () => { upload(fi.files); fi.value = ''; };
dz.ondragover = e => { e.preventDefault(); dz.classList.add('drag'); };
dz.ondragleave = () => dz.classList.remove('drag');
dz.ondrop = e => { e.preventDefault(); dz.classList.remove('drag'); upload(e.dataTransfer.files); };
load(); setInterval(load, 4000);
</script>
</body>
</html>''';

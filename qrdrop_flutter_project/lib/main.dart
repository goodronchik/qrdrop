import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'server.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QrDropApp());
}

class QrDropApp extends StatelessWidget {
  const QrDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QRDrop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2563EB),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3B82F6),
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final QrDropServer _server = QrDropServer();
  final TextEditingController _clipController = TextEditingController();
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _server.addListener(_onUpdate);
    _server.initAndStart();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _server.removeListener(_onUpdate);
    _server.dispose();
    _clipController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final paths = result.paths.whereType<String>().toList();
    if (paths.isNotEmpty) {
      _server.addFiles(paths);
      _snack('Добавлено файлов: ${paths.length}');
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _snack('Скопировано в буфер обмена');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 820;

    return Scaffold(
      appBar: AppBar(
        title: const Text('QRDrop — Обмен файлами'),
        actions: [
          IconButton(
            tooltip: 'Обновить сетевые адреса',
            onPressed: _server.refreshIps,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: _server.isRunning ? _server.stop : _server.start,
              icon: Icon(_server.isRunning ? Icons.stop : Icons.play_arrow),
              label: Text(_server.isRunning ? 'Стоп' : 'Старт'),
            ),
          ),
        ],
      ),
      body: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 360, child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _buildQrPanel())),
                const VerticalDivider(width: 1),
                Expanded(child: _buildMainTabs()),
              ],
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  _buildQrPanel(),
                  const SizedBox(height: 16),
                  _buildMobileContent(),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickFiles,
        icon: const Icon(Icons.add),
        label: const Text('Выбрать файлы'),
      ),
    );
  }

  Widget _buildQrPanel() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _server.isRunning ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                  color: _server.isRunning ? Colors.green : cs.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _server.isRunning ? 'Сервер активен' : 'Сервер остановлен',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_server.pin.isNotEmpty)
                  Chip(
                    label: Text('PIN: ${_server.pin}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (_server.lastError != null) ...[
              const SizedBox(height: 8),
              Text(_server.lastError!, style: TextStyle(color: cs.error)),
            ],
            const SizedBox(height: 14),
            if (_server.isRunning) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: _server.shareUrl,
                    version: QrVersions.auto,
                    size: 210,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        _server.shareUrl,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Копировать ссылку',
                      onPressed: () => _copy(_server.shareUrl),
                      icon: const Icon(Icons.copy, size: 18),
                    ),
                  ],
                ),
              ),
              if (_server.ips.length > 1) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _server.activeIp,
                  decoration: const InputDecoration(
                    labelText: 'Сетевой адрес (IP)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _server.ips
                      .map((ip) => DropdownMenuItem(value: ip, child: Text(ip)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) _server.setActiveIp(val);
                  },
                ),
              ],
            ],
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Защита токеном и PIN'),
              value: _server.requireAuth,
              onChanged: _server.setRequireAuth,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Только скачивание'),
              value: _server.readonly,
              onChanged: _server.setReadonly,
            ),
            if (_server.receiveDirPath.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Папка входящих файлов:\n${_server.receiveDirPath}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMainTabs() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, icon: const Icon(Icons.folder), label: Text('Файлы (${_server.listFiles().length})')),
              ButtonSegment(value: 1, icon: const Icon(Icons.notes), label: Text('Текст (${_server.clips.length})')),
            ],
            selected: {_tabIndex},
            onSelectionChanged: (s) => setState(() => _tabIndex = s.first),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
            child: _tabIndex == 0 ? _buildFilesList() : _buildClipsPanel(),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 0, icon: const Icon(Icons.folder), label: Text('Файлы (${_server.listFiles().length})')),
            ButtonSegment(value: 1, icon: const Icon(Icons.notes), label: Text('Текст (${_server.clips.length})')),
          ],
          selected: {_tabIndex},
          onSelectionChanged: (s) => setState(() => _tabIndex = s.first),
        ),
        const SizedBox(height: 12),
        _tabIndex == 0 ? _buildFilesList() : _buildClipsPanel(),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildFilesList() {
    final files = _server.listFiles();
    if (files.isEmpty) {
      return const Card(
        elevation: 0,
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Файлов пока нет.\nНажмите «Выбрать файлы» ниже или отправьте их с другого устройства через браузер.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: files.map((f) {
        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(f.isReceived ? Icons.download_done : Icons.insert_drive_file),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${formatSize(f.size)} • ${f.isReceived ? "Получен" : "Отправка"}'),
            trailing: IconButton(
              tooltip: 'Удалить из списка',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _server.removeFile(f.name),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildClipsPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _clipController,
                decoration: const InputDecoration(
                  hintText: 'Вставьте ссылку или заметку...',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                if (_clipController.text.trim().isNotEmpty) {
                  _server.addClip(_clipController.text);
                  _clipController.clear();
                }
              },
              child: const Text('Отправить'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_server.clips.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Текстовых заметок пока нет.', textAlign: TextAlign.center),
          )
        else
          ..._server.clips.map((c) => Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: SelectableText(c.text),
                  subtitle: Text('${c.sender} • ${c.time}'),
                  trailing: IconButton(
                    tooltip: 'Копировать',
                    icon: const Icon(Icons.copy),
                    onPressed: () => _copy(c.text),
                  ),
                ),
              )),
      ],
    );
  }
}

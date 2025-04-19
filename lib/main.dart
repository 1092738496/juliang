import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final deadline = DateTime(2025, 4, 22); // 超过 4月21日就不能启动
  final now = DateTime.now();
  if (now.isAfter(deadline)) {
  } else {
    runApp(MyApp());
  }
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '越进创客',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: WebViewShell(),
    );
  }
}

class Bookmark {
  final String title;
  final String url;

  Bookmark(this.title, this.url);

  Map<String, dynamic> toJson() => {'title': title, 'url': url};

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    return Bookmark(json['title'] ?? '', json['url'] ?? '');
  }
}

class WebViewShell extends StatefulWidget {
  @override
  State<WebViewShell> createState() => _WebViewShellState();
}

class _WebViewShellState extends State<WebViewShell> {
  List<Bookmark> _bookmarks = [];
  late File _bookmarkFile;
  Map<String, WebviewController> _winControllers = {};
  Map<String, WebViewController> _macControllers = {};
  Map<String, String> _urlStateMap = {};
  Map<String, String> _formDataMap = {};
  String? _currentUrl;
  final _titleController = TextEditingController();
  final _urlController = TextEditingController();
  final String _defaultUrl = 'https://teach.juliang-tech.com/#/diy?id=66';

  @override
  void initState() {
    super.initState();
    _initBookmarks();
  }

  Future<void> _initBookmarks() async {
    Directory dir;
    if (Platform.isMacOS) {
      dir = await getApplicationSupportDirectory();
    } else {
      dir = File(Platform.resolvedExecutable).parent;
    }
    _bookmarkFile = File(p.join(dir.path, 'bookmarks.json'));

    if (!await _bookmarkFile.exists()) {
      await _bookmarkFile.create(recursive: true);
      await _bookmarkFile.writeAsString(
        jsonEncode([
          {'title': '在线编程', 'url': 'https://oj.wzjl-tech.cn/'},
          {
            'title': '授课系统',
            'url': 'https://teach.juliang-tech.com/#/diy?id=66',
          },
        ]),
      );
    }

    try {
      final content = await _bookmarkFile.readAsString();
      final decoded = jsonDecode(content) as List;
      _bookmarks = decoded.map((e) => Bookmark.fromJson(e)).toList();
    } catch (_) {
      _bookmarks = [];
    }

    setState(() {});
    await Future.delayed(Duration(milliseconds: 100));
    await _loadBookmark(_defaultUrl);
  }

  Future<void> _saveBookmarks() async {
    final json = jsonEncode(_bookmarks.map((e) => e.toJson()).toList());
    await _bookmarkFile.writeAsString(json);
  }

  void _navigateBack() {
    if (_currentUrl == null) return;
    if (Platform.isWindows) {
      _winControllers[_currentUrl!]?.goBack();
    } else {
      _macControllers[_currentUrl!]?.goBack();
    }
  }

  void _navigateForward() {
    if (_currentUrl == null) return;
    if (Platform.isWindows) {
      _winControllers[_currentUrl!]?.goForward();
    } else {
      _macControllers[_currentUrl!]?.goForward();
    }
  }

  Future<void> _reload() async {
    if (_currentUrl == null) return;
    final urlKey = _currentUrl!;
    String realUrl = _urlStateMap[urlKey] ?? urlKey;
    String formBase64 = "";

    try {
      if (Platform.isWindows) {
        final controller = _winControllers[urlKey];
        final jsUrl = await controller?.executeScript("window.location.href");
        realUrl = jsUrl?.toString().replaceAll('"', '') ?? realUrl;

        final jsForm = await controller?.executeScript("""
          JSON.stringify(Array.from(document.querySelectorAll('input, textarea, select')).map(el => ({
            name: el.name || el.id,
            value: el.value
          })))
        """);
        formBase64 = base64.encode(utf8.encode(jsForm?.toString() ?? ""));
      } else {
        final controller = _macControllers[urlKey];
        final url = await controller?.currentUrl();
        if (url != null && url.isNotEmpty) realUrl = url;

        final jsForm = await controller?.runJavaScriptReturningResult("""
          JSON.stringify(Array.from(document.querySelectorAll('input, textarea, select')).map(el => ({
            name: el.name || el.id,
            value: el.value
          })))
        """);
        formBase64 = base64.encode(utf8.encode(jsForm?.toString() ?? ""));
      }
    } catch (_) {}

    _urlStateMap[urlKey] = realUrl;
    _formDataMap[urlKey] = formBase64;

    if (Platform.isWindows) {
      _winControllers.remove(urlKey);
      setState(() {});
      await Future.delayed(Duration(milliseconds: 50));
      final controller = WebviewController();
      await controller.initialize();
      await controller.loadUrl(realUrl);
      _winControllers[urlKey] = controller;
      setState(() {});
      if (formBase64.isNotEmpty) {
        await Future.delayed(Duration(milliseconds: 1000));
        controller.executeScript(_buildRestoreJS(formBase64));
      }
    } else {
      _macControllers.remove(urlKey);
      setState(() {});
      await Future.delayed(Duration(milliseconds: 50));
      final controller =
          WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setNavigationDelegate(
              NavigationDelegate(
                onPageFinished: (url) {
                  if (_currentUrl != null && url.isNotEmpty) {
                    _urlStateMap[_currentUrl!] = url;
                  }
                },
              ),
            )
            ..loadRequest(Uri.parse(realUrl));
      _macControllers[urlKey] = controller;
      setState(() {});
      if (formBase64.isNotEmpty) {
        await Future.delayed(Duration(milliseconds: 1000));
        controller.runJavaScript(_buildRestoreJS(formBase64));
      }
    }
  }

  String _buildRestoreJS(String base64Json) {
    return """
      (function(){
        function restoreForm(data){
          try {
            data.forEach(obj => {
              const el = document.querySelector('[name="' + obj.name + '"], [id="' + obj.name + '"]');
              if (el) el.value = obj.value;
            });
          } catch(e){}
        }
        function waitAndInject(data){
          if (document.readyState === 'complete') {
            restoreForm(data);
          } else {
            window.addEventListener('load', () => restoreForm(data));
          }
        }
        waitAndInject(JSON.parse(atob("$base64Json")));
      })();
    """;
  }

  Future<void> _loadBookmark(String url) async {
    setState(() {
      _currentUrl = url;
      _urlStateMap[url] = url;
    });

    if (Platform.isWindows) {
      if (!_winControllers.containsKey(url)) {
        final controller = WebviewController();
        await controller.initialize();
        await controller.loadUrl(url);
        _winControllers[url] = controller;
      }
    } else {
      if (!_macControllers.containsKey(url)) {
        final controller =
            WebViewController()
              ..setJavaScriptMode(JavaScriptMode.unrestricted)
              ..setNavigationDelegate(
                NavigationDelegate(
                  onPageFinished: (url) {
                    if (_currentUrl != null && url.isNotEmpty) {
                      _urlStateMap[_currentUrl!] = url;
                    }
                  },
                ),
              )
              ..loadRequest(Uri.parse(url));
        _macControllers[url] = controller;
      }
    }

    setState(() {});
  }

  void _showAddBookmarkDialog() {
    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text("添加书签"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _titleController,
                  decoration: InputDecoration(labelText: '标题'),
                ),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(labelText: '链接'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("取消"),
              ),
              ElevatedButton(
                onPressed: () {
                  final title = _titleController.text.trim();
                  final url = _urlController.text.trim();
                  if (title.isNotEmpty && url.isNotEmpty) {
                    setState(() {
                      _bookmarks.add(Bookmark(title, url));
                    });
                    _saveBookmarks();
                    _titleController.clear();
                    _urlController.clear();
                    Navigator.pop(context);
                  }
                },
                child: Text("保存"),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
            color: Colors.grey[100],
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back),
                  onPressed: _navigateBack,
                ),
                IconButton(
                  icon: Icon(Icons.arrow_forward),
                  onPressed: _navigateForward,
                ),
                IconButton(icon: Icon(Icons.refresh), onPressed: _reload),
                SizedBox(width: 16),
                ..._bookmarks.map(
                  (b) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor:
                            b.url == _currentUrl
                                ? Colors.lightBlue.shade100
                                : null,
                        side: BorderSide(
                          color:
                              b.url == _currentUrl
                                  ? Colors.blueAccent
                                  : Colors.grey,
                        ),
                      ),
                      onPressed: () => _loadBookmark(b.url),
                      child: Text(
                        b.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              b.url == _currentUrl
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                          color:
                              b.url == _currentUrl
                                  ? Colors.blueAccent
                                  : Colors.black,
                        ),
                      ),
                    ),
                  ),
                ),
                Spacer(),
                Image.asset("images/icon.png", width: 50, height: 50),
              ],
            ),
          ),
          Expanded(
            child:
                Platform.isWindows
                    ? (_currentUrl != null &&
                            _winControllers[_currentUrl!] != null
                        ? Webview(_winControllers[_currentUrl!]!)
                        : Center(child: CircularProgressIndicator()))
                    : (_currentUrl != null &&
                            _macControllers[_currentUrl!] != null
                        ? WebViewWidget(
                          controller: _macControllers[_currentUrl!]!,
                        )
                        : Center(child: Text("不支持的平台"))),
          ),
        ],
      ),
    );
  }
}

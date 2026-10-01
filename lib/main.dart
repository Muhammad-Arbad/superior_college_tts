import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

const kHomeUrl = 'https://portal.superiortts.com/mycollege/index.php';
const kHost = 'portal.superiortts.com';
const kBrand = Color(0xFF266D68);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: kBrand,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const PortalApp());
}

class PortalApp extends StatelessWidget {
  const PortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SUPERIOR COLLEGE T.T.S',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: kBrand, useMaterial3: true),
      home: const PortalPage(),
    );
  }
}

class PortalPage extends StatefulWidget {
  const PortalPage({super.key});

  @override
  State<PortalPage> createState() => _PortalPageState();
}

class _PortalPageState extends State<PortalPage> {
  InAppWebViewController? _web;
  late final PullToRefreshController _ptr;
  double _progress = 0;
  bool _offline = false;
  DateTime? _lastBack;

  @override
  void initState() {
    super.initState();
    _ptr = PullToRefreshController(
      settings: PullToRefreshSettings(color: kBrand),
      onRefresh: () async => _web?.reload(),
    );
  }

  // Anything outside the portal domain opens outside the app
  bool _isInternal(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') && uri.host == kHost;

  Future<NavigationActionPolicy> _onNavigate(Uri? uri) async {
    if (uri == null) return NavigationActionPolicy.ALLOW;
    if (uri.scheme == 'about' || uri.scheme == 'data' || uri.scheme == 'blob') {
      return NavigationActionPolicy.ALLOW;
    }
    if (_isInternal(uri)) {
      // WebView can't render PDFs inline, so download + open them
      if (uri.path.toLowerCase().endsWith('.pdf')) {
        _download(uri.toString(), null);
        return NavigationActionPolicy.CANCEL;
      }
      return NavigationActionPolicy.ALLOW;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationActionPolicy.CANCEL;
  }

  // Downloads with the webview's session cookies so logged-in files work
  Future<void> _download(String url, String? suggestedName) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Downloading...')));
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Cookie', cookies.map((c) => '${c.name}=${c.value}').join('; '));
      final res = await req.close();
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';

      var name = suggestedName;
      final cd = res.headers.value('content-disposition');
      if ((name == null || name.isEmpty) && cd != null) {
        final m = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
        name = m?.group(1);
      }
      if (name == null || name.isEmpty) {
        final seg = Uri.parse(url).pathSegments;
        name = seg.isNotEmpty && seg.last.contains('.')
            ? seg.last
            : 'file_${DateTime.now().millisecondsSinceEpoch}';
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name');
      await res.pipe(file.openWrite());
      client.close();

      messenger.hideCurrentSnackBar();
      await OpenFilex.open(file.path);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  Future<void> _onBack() async {
    if (_offline) {
      SystemNavigator.pop();
      return;
    }
    if (await _web?.canGoBack() ?? false) {
      await _web!.goBack();
      return;
    }
    // Double back to exit
    final now = DateTime.now();
    if (_lastBack == null || now.difference(_lastBack!) > const Duration(seconds: 2)) {
      _lastBack = now;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Press back again to exit'), duration: Duration(seconds: 2)),
      );
      return;
    }
    SystemNavigator.pop();
  }

  void _retry() {
    setState(() => _offline = false);
    _web?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(kHomeUrl)),
                pullToRefreshController: _ptr,
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  useShouldOverrideUrlLoading: true,
                  useOnDownloadStart: true,
                  supportMultipleWindows: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowFileAccess: true,
                  supportZoom: false,
                ),
                onWebViewCreated: (c) => _web = c,
                shouldOverrideUrlLoading: (c, action) => _onNavigate(action.request.url),
                // target="_blank" links open in the same view
                onCreateWindow: (c, action) async {
                  final url = action.request.url;
                  if (url != null) {
                    final policy = await _onNavigate(url);
                    if (policy == NavigationActionPolicy.ALLOW) {
                      c.loadUrl(urlRequest: URLRequest(url: url));
                    }
                  }
                  return false;
                },
                onDownloadStartRequest: (c, req) =>
                    _download(req.url.toString(), req.suggestedFilename),
                onPermissionRequest: (c, req) async {
                  if (req.resources.contains(PermissionResourceType.CAMERA)) {
                    await Permission.camera.request();
                  }
                  return PermissionResponse(
                    resources: req.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onProgressChanged: (c, p) {
                  if (p == 100) _ptr.endRefreshing();
                  setState(() => _progress = p / 100);
                },
                onLoadStop: (c, url) => _ptr.endRefreshing(),
                onReceivedError: (c, req, err) {
                  _ptr.endRefreshing();
                  if (req.isForMainFrame ?? false) setState(() => _offline = true);
                },
              ),
              if (_progress < 1 && !_offline)
                LinearProgressIndicator(value: _progress, color: kBrand, minHeight: 3),
              if (_offline) _OfflineView(onRetry: _retry),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset('assets/logo.png', width: 120),
          const SizedBox(height: 24),
          const Icon(Icons.wifi_off_rounded, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('No internet connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('Please check your connection and try again.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            style: FilledButton.styleFrom(backgroundColor: kBrand),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

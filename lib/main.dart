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
const kBrand = Color(0xFF3A89B6);
const kNavBar = Color(0xFF2C6A8E); // slightly darker shade for bottom nav
const kDrawerBg = Color(0xFF303030);
const _p = 'https://portal.superiortts.com/mycollege/student-panel';

class NavItem {
  const NavItem(this.label, this.icon, this.url);
  final String label;
  final IconData icon;
  final String url;
}

const kDrawerItems = [
  NavItem('Dashboard', Icons.dashboard, kHomeUrl),
  NavItem(
    'Attendance',
    Icons.calendar_today_outlined,
    '$_p/attendance-detail-month-wise.php',
  ),
  NavItem(
    'Fee Collections',
    Icons.confirmation_number,
    '$_p/fee-collection.php',
  ),
  NavItem(
    'Examinations',
    Icons.fact_check,
    '$_p/internal-examination-summary.php',
  ),
  NavItem('Date sheet', Icons.menu_book, '$_p/date-sheet.php'),
  NavItem('Profile', Icons.person, '$_p/change-your-profile-settings.php'),
  NavItem('Events', Icons.notification_add, '$_p/events-detail.php'),
  NavItem('SMS Inbox', Icons.sms, '$_p/sms-detail.php'),
];

const kBottomItems = [
  NavItem('Home', Icons.dashboard, kHomeUrl),
  NavItem('Attendance', Icons.event_available, '$_p/attendance-calendar.php'),
  NavItem('Fees', Icons.receipt_long, '$_p/fee-plan.php'),
  NavItem(
    'Examination',
    Icons.fact_check,
    '$_p/internal-examination-summary.php',
  ),
  NavItem('SMS', Icons.sms, '$_p/sms-detail.php'),
];

const kProfileUrl = '$_p/change-your-profile-settings.php';
const kPasswordUrl = '$_p/change-your-password.php';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: kBrand,
      statusBarIconBrightness: Brightness.light,
    ),
  );
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
  bool _pulling = false; // pull-to-refresh has its own spinner
  bool _offline = false;
  bool _showSplash = true;
  String _currentUrl = kHomeUrl;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  DateTime? _lastBack;

  @override
  void initState() {
    super.initState();
    _ptr = PullToRefreshController(
      settings: PullToRefreshSettings(color: kBrand),
      onRefresh: () async {
        _pulling = true;
        await _web?.reload();
      },
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
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(
        'Cookie',
        cookies.map((c) => '${c.name}=${c.value}').join('; '),
      );
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

  void _open(String url) {
    _scaffoldKey.currentState?.closeDrawer();
    setState(() {
      _offline = false;
      _currentUrl = url;
    });
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  // Drawer, menu and bottom nav only after login (student panel pages)
  bool get _inPanel =>
      (Uri.tryParse(_currentUrl)?.path ?? '').contains('/student-panel/');

  // Bottom tab matching the current page (-1 = none)
  int get _bottomIndex {
    final path = Uri.tryParse(_currentUrl)?.path ?? '';
    return kBottomItems.indexWhere((i) => Uri.parse(i.url).path == path);
  }

  Future<void> _onBack() async {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      _scaffoldKey.currentState!.closeDrawer();
      return;
    }
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
    if (_lastBack == null ||
        now.difference(_lastBack!) > const Duration(seconds: 2)) {
      _lastBack = now;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
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
      child: Stack(
        children: [
          Scaffold(
            key: _scaffoldKey,
            backgroundColor: Colors.white,
            appBar: AppBar(
              backgroundColor: kBrand,
              foregroundColor: Colors.white,
              automaticallyImplyLeading: _inPanel,
              title: const Text(
                'Superior College T.T.S',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              actions: [
                if (_inPanel)
                  PopupMenuButton<String>(
                    color: kDrawerBg,
                    onSelected: (v) {
                      if (v == 'exit') {
                        SystemNavigator.pop();
                      } else {
                        _open(v);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: kProfileUrl,
                        child: _MenuText('My Profile'),
                      ),
                      PopupMenuItem(
                        value: kPasswordUrl,
                        child: _MenuText('Change Password'),
                      ),
                      PopupMenuItem(value: 'exit', child: _MenuText('Exit')),
                    ],
                  ),
              ],
            ),
            drawer: _inPanel ? _AppDrawer(onTap: _open) : null,
            bottomNavigationBar: !_inPanel
                ? null
                : _BottomBar(
                    selected: _bottomIndex,
                    onTap: (i) => _open(kBottomItems[i].url),
                  ),
            body: Stack(
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
                  onUpdateVisitedHistory: (c, url, _) {
                    if (url != null) {
                      setState(() => _currentUrl = url.toString());
                    }
                  },
                  shouldOverrideUrlLoading: (c, action) =>
                      _onNavigate(action.request.url),
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
                  onDownloadStarting: (c, req) async {
                    _download(req.url.toString(), req.suggestedFilename);
                    return null;
                  },
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
                    if (p == 100) {
                      _ptr.endRefreshing();
                      _pulling = false;
                    }
                    setState(() => _progress = p / 100);
                  },
                  onLoadStop: (c, url) => _ptr.endRefreshing(),
                  onReceivedError: (c, req, err) {
                    _ptr.endRefreshing();
                    if (req.isForMainFrame ?? false) {
                      setState(() => _offline = true);
                    }
                  },
                ),
                // Loader on every page change (skipped during pull-to-refresh)
                if (_progress < 1 && !_offline && !_showSplash && !_pulling)
                  Positioned.fill(
                    child: Container(
                      color: Colors.white.withValues(alpha: 0.6),
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(color: kBrand),
                    ),
                  ),
                if (_offline) _OfflineView(onRetry: _retry),
              ],
            ),
          ),
          // Splash covers app bar + nav too; portal loads behind it
          if (_showSplash)
            _AnimatedSplash(onDone: () => setState(() => _showSplash = false)),
        ],
      ),
    );
  }
}

class _MenuText extends StatelessWidget {
  const _MenuText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: Colors.white, fontSize: 16));
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({required this.onTap});
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: kDrawerBg,
      shape: const RoundedRectangleBorder(),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: kBrand,
            padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.of(context).padding.top + 24,
              24,
              24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.asset('assets/logo_round.png', width: 92, height: 92),
                const SizedBox(height: 16),
                const Text(
                  'Superior College T.T.S',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final item in kDrawerItems)
                  ListTile(
                    leading: Icon(item.icon, color: Colors.white70),
                    title: Text(
                      item.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 2,
                    ),
                    onTap: () => onTap(item.url),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.selected, required this.onTap});
  final int selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kNavBar,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < kBottomItems.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onTap(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          kBottomItems[i].icon,
                          color: i == selected
                              ? Colors.white
                              : const Color(0xFFB9DDF2),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          kBottomItems[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: i == selected
                                ? Colors.white
                                : const Color(0xFFB9DDF2),
                            fontWeight: i == selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Logo slides up from below to the center (same feel as EAP Plus), then fades out
class _AnimatedSplash extends StatefulWidget {
  const _AnimatedSplash({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_AnimatedSplash> createState() => _AnimatedSplashState();
}

class _AnimatedSplashState extends State<_AnimatedSplash>
    with TickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _slide,
    curve: Curves.easeInOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _slide.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    await _fade.forward();
    widget.onDone();
  }

  @override
  void dispose() {
    _slide.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(_fade),
      child: Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: AnimatedBuilder(
          animation: _curve,
          builder: (context, child) => Transform.translate(
            // Starts near the bottom edge, ends at center
            offset: Offset(0, (1 - _curve.value) * size.height * 0.45),
            child: Opacity(opacity: _curve.value.clamp(0.0, 1.0), child: child),
          ),
          child: Image.asset('assets/logo.png', width: size.width * 0.45),
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
          const Text(
            'No internet connection',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Please check your connection and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
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

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, HttpHeaders, HttpClient;
import 'dart:math';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as af_core;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

// ============================================================================
// Константы
// ============================================================================
const String kBurrowStatEndpoint = "https://helper.greengarden.casa/stat";

// ============================================================================
// Логирование
// ============================================================================
void candyLogInfo(Object msg) => debugPrint("[I] $msg");
void candyLogWarn(Object msg) => debugPrint("[W] $msg");
void candyLogError(Object msg) => debugPrint("[E] $msg");

// ============================================================================
// Сеть
// ============================================================================
class CandyNetClient {
  Future<void> sendJsonPost(String url, Map<String, dynamic> data) async {
    try {
      final res = await http.post(
        Uri.parse(url),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(data),
      );
      candyLogInfo("POST $url => ${res.statusCode}");
    } catch (e) {
      candyLogError("sendJsonPost error: $e");
    }
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================
class CandyDeviceProfile {
  String? candyDeviceId;
  String? candyInstanceId = "solo-bunny";
  String? candyPlatform;
  String? candyOsBuild;
  String? candyAppVersion;
  String? candyLanguage;
  String? candyTimezone;
  bool candyPushAllowed = true; // заглушка

  Future<void> prepareCandyDevice() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      candyDeviceId = android.id;
      candyPlatform = "android";
      candyOsBuild = android.version.release;
    } else if (Platform.isIOS) {
      final ios = await info.iosInfo;
      candyDeviceId = ios.identifierForVendor;
      candyPlatform = "ios";
      candyOsBuild = ios.systemVersion;
    }

    final pkg = await PackageInfo.fromPlatform();
    candyAppVersion = pkg.version;
    candyLanguage = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    candyTimezone = tz_zone.local.name;
    candyInstanceId = "warren-${DateTime.now().millisecondsSinceEpoch}";
  }

  Map<String, dynamic> toMap({String? carrot}) => {
    "fcm_token": carrot ?? 'missing_carrot',
    "device_id": candyDeviceId ?? 'missing_rabbit',
    "app_name": "candymood",
    "instance_id": candyInstanceId ?? 'missing_warren',
    "platform": candyPlatform ?? 'missing_platform',
    "os_version": candyOsBuild ?? 'missing_os',
    "app_version": candyAppVersion ?? 'missing_app',
    "language": candyLanguage ?? 'en',
    "timezone": candyTimezone ?? 'UTC',
    "push_enabled": candyPushAllowed,
  };
}

// ============================================================================
// AppsFlyer
// ============================================================================
class CandyAdvisor with ChangeNotifier {
  af_core.AppsFlyerOptions? candyAfOptions;
  af_core.AppsflyerSdk? candyAfSdk;

  String candyAfUserId = "";
  String candyAfDataRaw = "";

  void startCandyAdvisor(VoidCallback markDirty) {
    final cfg = af_core.AppsFlyerOptions(
      afDevKey: "qsBLmy7dAXDQhowM8V3ca4",
      appId: "6756121025",
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );
    candyAfOptions = cfg;
    candyAfSdk = af_core.AppsflyerSdk(cfg);

    candyAfSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );
    candyAfSdk?.startSDK(
      onSuccess: () => candyLogInfo("CandyAdvisor started"),
      onError: (int c, String m) => candyLogError("CandyAdvisor error $c: $m"),
    );
    candyAfSdk?.onInstallConversionData((data) {
      candyAfDataRaw = data.toString();
      markDirty();
      notifyListeners();
    });
    candyAfSdk?.getAppsFlyerUID().then((v) {
      candyAfUserId = v.toString();
      markDirty();
      notifyListeners();
    });
  }
}

// ============================================================================
// Cargo модель
// ============================================================================
class CandyCargoModel {
  final CandyDeviceProfile candyDevice;
  final CandyAdvisor candyAdvisor;

  CandyCargoModel({
    required this.candyDevice,
    required this.candyAdvisor,
  });

  Map<String, dynamic> buildDevicePayload(String? carrot) =>
      candyDevice.toMap(carrot: carrot);

  Map<String, dynamic> buildAfPayload(String? carrot) => {
    "content": {
      "af_data": candyAdvisor.candyAfDataRaw,
      "af_id": candyAdvisor.candyAfUserId,
      "fb_app_name": "candymood",
      "app_name": "candymood",
      "deep": null,
      "bundle_identifier": "com.swee.cande.candymood",
      "app_version": "1.0.0",
      "apple_id": "6756121025",
      "fcm_token": carrot ?? "no_carrot",
      "device_id": candyDevice.candyDeviceId ?? "no_rabbit",
      "instance_id": candyDevice.candyInstanceId ?? "no_warren",
      "platform": candyDevice.candyPlatform ?? "no_platform",
      "os_version": candyDevice.candyOsBuild ?? "no_os",
      "app_version": candyDevice.candyAppVersion ?? "no_app",
      "language": candyDevice.candyLanguage ?? "en",
      "timezone": candyDevice.candyTimezone ?? "UTC",
      "push_enabled": candyDevice.candyPushAllowed,
      "useruid": candyAdvisor.candyAfUserId,
    },
  };
}

// ============================================================================
// Портовый рабочий (WebView взаимодействие)
// ============================================================================
class CandyPorter {
  final CandyCargoModel candyCargoModel;
  final InAppWebViewController Function() candyPickWebController;

  String? lastVisitedUrl;
  int lastPostMs = 0;
  static const int throttleMs = 2000;

  CandyPorter({
    required this.candyCargoModel,
    required this.candyPickWebController,
  });

  Future<void> saveDeviceInLocalStorage(String? carrot) async {
    final map = candyCargoModel.buildDevicePayload(carrot);
    await candyPickWebController().evaluateJavascript(source: '''
try { localStorage.setItem('app_data', JSON.stringify(${jsonEncode(map)})); } catch (_) {}
''');
  }

  Future<void> sendAppsFlyerRaw(String? carrot, {String? currentUrl}) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (now - lastPostMs < throttleMs) {
      candyLogWarn("sendAppsFlyerRaw throttled (time)");
      return;
    }
    if (currentUrl != null && lastVisitedUrl == currentUrl) {
      candyLogWarn("sendAppsFlyerRaw skipped (same url)");
      return;
    }

    final payload = candyCargoModel.buildAfPayload(carrot);
    final jsonString = jsonEncode(payload);
    candyLogInfo("sendAppsFlyerRaw: $jsonString");

    await candyPickWebController()
        .evaluateJavascript(source: "try { sendRawData(${jsonEncode(jsonString)}); } catch(_) {}");

    lastPostMs = now;
    if (currentUrl != null) lastVisitedUrl = currentUrl;
  }
}

// ============================================================================
// Кэш "морковки" (FCM токен)
// ============================================================================
class CandyCarrotStore {
  String? carrotValue;

  String? get currentCarrot => carrotValue;

  Future<void> initOrCreateCarrot() async {
    carrotValue ??= "carrot-${DateTime.now().millisecondsSinceEpoch}";
  }

  void updateCarrot(String s) {
    if (s.isEmpty) return;
    carrotValue = s;
  }
}

// ============================================================================
// Статистика
// ============================================================================
Future<String> resolveFinalUrl(String startUrl, {int maxHops = 10}) async {
  final client = HttpClient();

  try {
    var current = Uri.parse(startUrl);
    for (int i = 0; i < maxHops; i++) {
      final req = await client.getUrl(current);
      req.followRedirects = false;
      final res = await req.close();
      if (res.isRedirect) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        if (loc == null || loc.isEmpty) break;
        final next = Uri.parse(loc);
        current = next.hasScheme ? next : current.resolveUri(next);
        continue;
      }
      return current.toString();
    }
    return current.toString();
  } catch (e) {
    debugPrint("resolveFinalUrl error: $e");
    return startUrl;
  } finally {
    client.close(force: true);
  }
}

Future<void> sendCandyStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appCarrot,
  int? firstPageLoadTs,
}) async {
  try {
    final finalUrl = await resolveFinalUrl(url);
    final payload = {
      "event": event,
      "timestart": timeStart,
      "timefinsh": timeFinish,
      "url": finalUrl,
      "appleID": "6754763897",
      "open_count": "$appCarrot/$timeStart",
    };

    debugPrint("candystat $payload");
    final res = await http.post(
      Uri.parse("$kBurrowStatEndpoint/$appCarrot"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );
    debugPrint("sendCandyStat status=${res.statusCode} body=${res.body}");
  } catch (e) {
    debugPrint("sendCandyStat error: $e");
  }
}

// ============================================================================
// CANDY Loader: переливающееся слово "CANDY"
// ============================================================================
class CandyTextLoader extends StatefulWidget {
  const CandyTextLoader({Key? key}) : super(key: key);

  @override
  State<CandyTextLoader> createState() => _CandyTextLoaderState();
}

class _CandyTextLoaderState extends State<CandyTextLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController candyAnimController;

  @override
  void initState() {
    super.initState();
    candyAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    candyAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: AnimatedBuilder(
          animation: candyAnimController,
          builder: (context, _) {
            final t = candyAnimController.value;
            final colors = [
              const Color(0xFFFF5F6D),
              const Color(0xFFFFC371),
              const Color(0xFF42E695),
              const Color(0xFF3BB2B8),
              const Color(0xFF7F00FF),
            ];

            // сдвиг градиента
            final beginOffset = Offset(-1.0 + 2.0 * t, 0);
            final endOffset = Offset(1.0 + 2.0 * t, 0);

            return ShaderMask(
              shaderCallback: (Rect bounds) {
                return LinearGradient(
                  colors: colors,
                  begin: Alignment(-1.0 + 2.0 * t, 0), // вариант через Alignment
                  end: Alignment(1.0 + 2.0 * t, 0),
                  tileMode: TileMode.mirror,
                ).createShader(bounds);
              },
              child: const Text(
                'CANDY',
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 8,
                  color: Colors.white, // закрашивается шейдером
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// Внешние URL: платформенный канал
// ============================================================================
class CandyExternalOpener {
  static const MethodChannel candyExternalChannel =
  MethodChannel('com.example.egg/external');

  static Future<bool> openExternalLink(Uri uri) async {
    try {
      final ok = await candyExternalChannel.invokeMethod<bool>(
        'openExternalUri',
        {'uri': uri.toString()},
      );
      return ok ?? false;
    } catch (e) {
      candyLogError("openExternalLink failed: $e");
      return false;
    }
  }
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================
class CandyHarborPage extends StatefulWidget {
  final String? carrot;
  const CandyHarborPage({super.key, required this.carrot});

  @override
  State<CandyHarborPage> createState() => _CandyHarborPageState();
}

class _CandyHarborPageState extends State<CandyHarborPage>
    with WidgetsBindingObserver {
  late InAppWebViewController candyWebController;
  bool candyBusyFlag = false;

  final String candyHomeUrl = "https://helper.greengarden.casa/";

  final CandyDeviceProfile candyDeviceProfile = CandyDeviceProfile();
  final CandyAdvisor candyAdvisor = CandyAdvisor();

  DateTime? pausedAt;
  bool veilHidden = false;
  bool coverVisible = true;

  bool loadedEventSent = false;
  int? firstPageTs;

  CandyPorter? candyPorter;
  CandyCargoModel? candyCargoModel;

  String currentUrlString = "";
  int pageLoadStartTs = 0;

  final Map<String, bool> afPushedForUrl = {};
  final Set<String> platformSchemes = {
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> externalHosts = {
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
    'bnl.com',
    'www.bnl.com',
  };

  final CandyCarrotStore candyCarrotStore = CandyCarrotStore();
  bool bootAfSentOnce = false;
  bool notificationHandlerBound = false;
  bool serverResponseHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    firstPageTs = DateTime.now().millisecondsSinceEpoch;

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => coverVisible = false);
    });

    Future.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() => veilHidden = true);
    });

    bootCandyHarbor();
  }

  Future<void> sendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (loadedEventSent) {
      debugPrint("Bunny Loaded already sent, skipping");
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await sendCandyStat(
      event: "Loaded",
      timeStart: timestart,
      timeFinish: now,
      url: url,
      appCarrot: candyAdvisor.candyAfUserId,
      firstPageLoadTs: firstPageTs,
    );
    loadedEventSent = true;
  }

  void bootCandyHarbor() async {
    candyAdvisor.startCandyAdvisor(() => setState(() {}));
    bindNotificationTap();
    await prepareCandyDevice();

    Future.delayed(const Duration(seconds: 6), () async {
      if (!bootAfSentOnce) {
        bootAfSentOnce = true;
        await pushAppsFlyerData(
          currentUrl: currentUrlString.isEmpty ? candyHomeUrl : currentUrlString,
        );
      }
      await pushDeviceToWeb();
    });
  }

  void bindNotificationTap() {
    if (notificationHandlerBound) return;
    notificationHandlerBound = true;

    const MethodChannel ch = MethodChannel('com.example.egg/notification');
    ch.setMethodCallHandler((call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> payload =
        Map<String, dynamic>.from(call.arguments);
        final uri = payload["uri"]?.toString();
        if (uri != null && uri.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => CandyWatchtowerPage(uri)),
                  (route) => false,
            );
          });
        }
      }
      return null;
    });
  }

  Future<void> prepareCandyDevice() async {
    try {
      await candyDeviceProfile.prepareCandyDevice();
      await candyCarrotStore.initOrCreateCarrot();
      candyCargoModel = CandyCargoModel(
        candyDevice: candyDeviceProfile,
        candyAdvisor: candyAdvisor,
      );
      candyPorter = CandyPorter(
        candyCargoModel: candyCargoModel!,
        candyPickWebController: () => candyWebController,
      );
    } catch (e) {
      candyLogError("prepareCandyDevice fail: $e");
    }
  }

  Future<void> pushDeviceToWeb() async {
    candyLogInfo("CARROT ship ${widget.carrot}");
    if (!mounted) return;
    setState(() => candyBusyFlag = true);
    try {
      final carrot = (widget.carrot != null && widget.carrot!.isNotEmpty)
          ? widget.carrot
          : candyCarrotStore.currentCarrot;
      await candyPorter?.saveDeviceInLocalStorage(carrot);
    } finally {
      if (mounted) setState(() => candyBusyFlag = false);
    }
  }

  Future<void> pushAppsFlyerData({String? currentUrl}) async {
    final carrot = (widget.carrot != null && widget.carrot!.isNotEmpty)
        ? widget.carrot
        : candyCarrotStore.currentCarrot;
    await candyPorter?.sendAppsFlyerRaw(carrot, currentUrl: currentUrl);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      pausedAt = DateTime.now();
    }
    if (s == AppLifecycleState.resumed) {
      if (Platform.isIOS && pausedAt != null) {
        final now = DateTime.now();
        final drift = now.difference(pausedAt!);
        if (drift > const Duration(minutes: 25)) {
          restartHarbor();
        }
      }
      pausedAt = null;
    }
  }

  void restartHarbor() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) => CandyHarborPage(carrot: widget.carrot),
        ),
            (route) => false,
      );
    });
  }

  // ================== URL helpers ==================
  bool isBareEmailUri(Uri u) {
    final s = u.scheme;
    if (s.isNotEmpty) return false;
    final raw = u.toString();
    return raw.contains('@') && !raw.contains(' ');
  }

  Uri convertToMailto(Uri u) {
    final full = u.toString();
    final parts = full.split('?');
    final email = parts.first;
    final qp =
    parts.length > 1 ? Uri.splitQueryString(parts[1]) : <String, String>{};
    return Uri(scheme: 'mailto', path: email, queryParameters: qp.isEmpty ? null : qp);
  }

  bool isPlatformishUri(Uri u) {
    final s = u.scheme.toLowerCase();
    if (platformSchemes.contains(s)) return true;

    if (s == 'http' || s == 'https') {
      final h = u.host.toLowerCase();
      if (externalHosts.contains(h)) return true;
      if (h.endsWith('t.me')) return true;
      if (h.endsWith('wa.me')) return true;
      if (h.endsWith('m.me')) return true;
      if (h.endsWith('signal.me')) return true;
    }
    return false;
  }

  Uri convertToHttpPlatformUri(Uri u) {
    final s = u.scheme.toLowerCase();

    if (s == 'tg' || s == 'telegram') {
      final qp = u.queryParameters;
      final domain = qp['domain'];
      if (domain != null && domain.isNotEmpty) {
        return Uri.https('t.me', '/$domain',
            {if (qp['start'] != null) 'start': qp['start']!});
      }
      final path = u.path.isNotEmpty ? u.path : '';
      return Uri.https(
          't.me', '/$path', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    if ((s == 'http' || s == 'https') && u.host.toLowerCase().endsWith('t.me')) {
      return u;
    }

    if (s == 'viber') return u;

    if (s == 'whatsapp') {
      final qp = u.queryParameters;
      final phone = qp['phone'];
      final text = qp['text'];
      if (phone != null && phone.isNotEmpty) {
        return Uri.https('wa.me', '/${stripToDigits(phone)}',
            {if (text != null && text.isNotEmpty) 'text': text});
      }
      return Uri.https('wa.me', '/',
          {if (text != null && text.isNotEmpty) 'text': text});
    }

    if ((s == 'http' || s == 'https') &&
        (u.host.toLowerCase().endsWith('wa.me') ||
            u.host.toLowerCase().endsWith('whatsapp.com'))) {
      return u;
    }

    if (s == 'skype') return u;

    if (s == 'fb-messenger') {
      final path = u.pathSegments.isNotEmpty ? u.pathSegments.join('/') : '';
      final qp = u.queryParameters;
      final id = qp['id'] ?? qp['user'] ?? path;
      if (id.isNotEmpty) {
        return Uri.https(
            'm.me', '/$id', u.queryParameters.isEmpty ? null : u.queryParameters);
      }
      return Uri.https(
          'm.me', '/', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    if (s == 'sgnl') {
      final qp = u.queryParameters;
      final ph = qp['phone'];
      final un = u.queryParameters['username'];
      if (ph != null && ph.isNotEmpty) {
        return Uri.https('signal.me', '/#p/${stripToDigits(ph)}');
      }
      if (un != null && un.isNotEmpty) {
        return Uri.https('signal.me', '/#u/$un');
      }
      final path = u.pathSegments.join('/');
      if (path.isNotEmpty) {
        return Uri.https('signal.me', '/$path',
            u.queryParameters.isEmpty ? null : u.queryParameters);
      }
      return u;
    }

    if (s == 'tel') return Uri.parse('tel:${stripToDigits(u.path)}');
    if (s == 'mailto') return u;

    if (s == 'bnl') {
      final newPath = u.path.isNotEmpty ? u.path : '';
      return Uri.https('bnl.com', '/$newPath',
          u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    return u;
  }

  Future<bool> openMailInExternal(Uri mailto) async {
    return await CandyExternalOpener.openExternalLink(mailto);
  }

  Future<bool> openExternal(Uri u) async {
    return await CandyExternalOpener.openExternalLink(u);
  }

  String stripToDigits(String s) => s.replaceAll(RegExp(r'[^0-9+]'), '');

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            if (coverVisible)
              const CandyTextLoader()
            else
              Container(
                color: Colors.white,
                child: Stack(
                  children: [
                    InAppWebView(
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        disableDefaultErrorPage: true,
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        allowsPictureInPictureMediaPlayback: true,
                        useOnDownloadStart: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        useShouldOverrideUrlLoading: true,
                        supportMultipleWindows: true,
                        transparentBackground: false,
                      ),
                      initialUrlRequest:
                      URLRequest(url: WebUri(candyHomeUrl)),
                      onWebViewCreated: (controller) {
                        candyWebController = controller;

                        candyCargoModel ??= CandyCargoModel(
                          candyDevice: candyDeviceProfile,
                          candyAdvisor: candyAdvisor,
                        );
                        candyPorter ??= CandyPorter(
                          candyCargoModel: candyCargoModel!,
                          candyPickWebController: () => candyWebController,
                        );

                        candyWebController.addJavaScriptHandler(
                          handlerName: 'onServerResponse',
                          callback: (args) {
                            if (serverResponseHandled) {
                              if (args.isEmpty) return null;
                              try {
                                return args.reduce(
                                        (curr, next) => curr + next);
                              } catch (_) {
                                return args.first;
                              }
                            }
                            try {
                              final saved = args.isNotEmpty &&
                                  args[0] is Map &&
                                  args[0]['savedata'].toString() == "false";

                              print("datasaved " +
                                  args[0]['savedata'].toString());
                              if (saved && !serverResponseHandled) {
                                serverResponseHandled = true;

                              }
                            } catch (_) {}
                            if (args.isEmpty) return null;
                            try {
                              return args.reduce(
                                      (curr, next) => curr + next);
                            } catch (_) {
                              return args.first;
                            }
                          },
                        );
                      },
                      onLoadStart: (controller, url) async {
                        setState(() {
                          pageLoadStartTs =
                              DateTime.now().millisecondsSinceEpoch;
                          candyBusyFlag = true;
                        });
                        if (url != null) {
                          if (isBareEmailUri(url)) {
                            try {
                              await controller.stopLoading();
                            } catch (_) {}
                            final mailto = convertToMailto(url);
                            await openMailInExternal(mailto);
                            return;
                          }
                          final sch = url.scheme.toLowerCase();
                          if (sch != 'http' && sch != 'https') {
                            try {
                              await controller.stopLoading();
                            } catch (_) {}
                          }
                        }
                      },
                      onLoadError:
                          (controller, url, code, message) async {
                        final now =
                            DateTime.now().millisecondsSinceEpoch;
                        final ev =
                            "InAppWebViewError(code=$code, message=$message)";
                        await sendCandyStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: url?.toString() ?? '',
                          appCarrot: candyAdvisor.candyAfUserId,
                          firstPageLoadTs: firstPageTs,
                        );
                        if (mounted) setState(() => candyBusyFlag = false);
                      },
                      onReceivedHttpError: (controller, request, errorResponse) async {
                        final now =
                            DateTime.now().millisecondsSinceEpoch;
                        final ev =
                            "HTTPError(status=${errorResponse.statusCode}, reason=${errorResponse.reasonPhrase})";
                        await sendCandyStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: request.url?.toString() ?? '',
                          appCarrot: candyAdvisor.candyAfUserId,
                          firstPageLoadTs: firstPageTs,
                        );
                      },
                      onReceivedError: (controller, request, error) async {
                        final now =
                            DateTime.now().millisecondsSinceEpoch;
                        final desc = (error.description ?? '').toString();
                        final ev =
                            "WebResourceError(code=${error}, message=$desc)";
                        await sendCandyStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: request.url?.toString() ?? '',
                          appCarrot: candyAdvisor.candyAfUserId,
                          firstPageLoadTs: firstPageTs,
                        );
                      },
                      onLoadStop: (controller, url) async {
                        await controller.evaluateJavascript(
                            source: "console.log('Bunny Harbor up!');");

                        final urlStr = url?.toString() ?? '';
                        setState(() => currentUrlString = urlStr);

                        await pushDeviceToWeb();

                        if (urlStr.isNotEmpty &&
                            afPushedForUrl[urlStr] != true) {
                          afPushedForUrl[urlStr] = true;
                          await pushAppsFlyerData(currentUrl: urlStr);
                        }

                        Future.delayed(const Duration(seconds: 20), () {
                          sendLoadedOnce(
                            url: currentUrlString.toString(),
                            timestart: pageLoadStartTs,
                          );
                        });

                        if (mounted) setState(() => candyBusyFlag = false);
                      },
                      shouldOverrideUrlLoading:
                          (controller, navAction) async {
                        final uri = navAction.request.url;
                        if (uri == null) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        if (isBareEmailUri(uri)) {
                          final mailto = convertToMailto(uri);
                          await openMailInExternal(mailto);
                          return NavigationActionPolicy.CANCEL;
                        }

                        final sch = uri.scheme.toLowerCase();

                        if (sch == 'mailto') {
                          await openMailInExternal(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (sch == 'tel') {
                          await openExternal(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (isPlatformishUri(uri)) {
                          final web = convertToHttpPlatformUri(uri);
                          if (web.scheme == 'http' ||
                              web.scheme == 'https') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    CandyDeckPage(web.toString()),
                              ),
                            );
                          } else {
                            await openExternal(uri);
                          }
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (sch != 'http' && sch != 'https') {
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onCreateWindow: (controller, req) async {
                        final uri = req.request.url;
                        if (uri == null) return false;

                        if (isBareEmailUri(uri)) {
                          final mailto = convertToMailto(uri);
                          await openMailInExternal(mailto);
                          return false;
                        }

                        final sch = uri.scheme.toLowerCase();

                        if (sch == 'mailto') {
                          await openMailInExternal(uri);
                          return false;
                        }

                        if (sch == 'tel') {
                          await openExternal(uri);
                          return false;
                        }

                        if (isPlatformishUri(uri)) {
                          final web = convertToHttpPlatformUri(uri);
                          if (web.scheme == 'http' ||
                              web.scheme == 'https') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    CandyDeckPage(web.toString()),
                              ),
                            );
                          } else {
                            await openExternal(uri);
                          }
                          return false;
                        }

                        if (sch == 'http' || sch == 'https') {
                          controller.loadUrl(
                            urlRequest: URLRequest(url: uri),
                          );
                        }
                        return false;
                      },
                      onDownloadStartRequest:
                          (controller, req) async {
                        await openExternal(req.url);
                      },
                    ),
                    Visibility(
                      visible: !veilHidden,
                      child: const CandyTextLoader(),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Внешний WebView
// ============================================================================
class CandyDeckPage extends StatefulWidget {
  final String url;
  const CandyDeckPage(this.url, {super.key});

  @override
  State<CandyDeckPage> createState() => _CandyDeckPageState();
}

class _CandyDeckPageState extends State<CandyDeckPage> {
  late InAppWebViewController candyDeckController;

  @override
  Widget build(BuildContext context) {
    final night =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: night ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: InAppWebView(
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            disableDefaultErrorPage: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            allowsPictureInPictureMediaPlayback: true,
            useOnDownloadStart: true,
            javaScriptCanOpenWindowsAutomatically: true,
            useShouldOverrideUrlLoading: true,
            supportMultipleWindows: true,
          ),
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          onWebViewCreated: (controller) => candyDeckController = controller,
        ),
      ),
    );
  }
}

// ============================================================================
// Help
// ============================================================================


// ============================================================================
// Вышка-наблюдатель
// ============================================================================
class CandyWatchtowerPage extends StatefulWidget {
  final String url;
  const CandyWatchtowerPage(this.url, {super.key});

  @override
  State<CandyWatchtowerPage> createState() => _CandyWatchtowerPageState();
}

class _CandyWatchtowerPageState extends State<CandyWatchtowerPage> {
  @override
  Widget build(BuildContext context) {
    return CandyDeckPage(widget.url);
  }
}

// ============================================================================
// Стартовый экран
// ============================================================================
class CandyBurrowStart extends StatefulWidget {
  const CandyBurrowStart({Key? key}) : super(key: key);

  @override
  State<CandyBurrowStart> createState() => _CandyBurrowStartState();
}

class _CandyBurrowStartState extends State<CandyBurrowStart> {
  final CandyCarrotStore candyCarrotStore = CandyCarrotStore();
  bool goOnce = false;
  Timer? fallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));

    prepareStart();
  }

  Future<void> prepareStart() async {
    await candyCarrotStore.initOrCreateCarrot();
    const MethodChannel ch = MethodChannel('com.example.egg/yolk');
    ch.setMethodCallHandler((call) async {
      if (call.method == 'setYolk') {
        final String s = call.arguments as String;
        if (s.isNotEmpty) candyCarrotStore.updateCarrot(s);
      }
      return null;
    });

    navigateToHarbor(candyCarrotStore.currentCarrot ?? "");
    fallbackTimer = Timer(const Duration(seconds: 8), () {
      if (!goOnce) {
        navigateToHarbor(candyCarrotStore.currentCarrot ?? "");
      }
    });
  }

  void navigateToHarbor(String sig) {
    if (goOnce) return;
    goOnce = true;
    fallbackTimer?.cancel();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CandyHarborPage(carrot: sig),
        ),
      );
    });
  }

  @override
  void dispose() {
    fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(child: CandyTextLoader()),
    );
  }
}

// ============================================================================
// main()
// ============================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }
  tz_data.initializeTimeZones();

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const CandyBurrowStart(),
    ),
  );
}
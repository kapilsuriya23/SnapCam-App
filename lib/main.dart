import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'auth.dart' show Auth;
import 'login_page.dart' show LoginPage;

// ═══════════════════════════════════════════════════════════════════════════════
// GLOBALS & CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════
late List<CameraDescription> cameras;
const _ch = MethodChannel('com.example.app/media_store');

// Brand colours
const _kRed = Color(0xFFFF3B30);
const _kYellow = Color(0xFFFFD60A);

// Pre-baked alpha variants
const _kRedGlow = Color(0x99FF3B30);
const _kRedShadow = Color(0x80FF3B30);
const _kWhite12 = Color(0x1FFFFFFF);
const _kWhite20 = Color(0x33FFFFFF);
const _kWhite30 = Color(0x4DFFFFFF);
const _kWhite40 = Color(0x66FFFFFF);
const _kWhite60 = Color(0x99FFFFFF);
const _kWhite90 = Color(0xE6FFFFFF);
const _kBlack45 = Color(0x73000000);
const _kBlack50 = Color(0x80000000);
const _kBlack54 = Color(0x8A000000);
const _kBlack72 = Color(0xB8000000);
const _kBlack85 = Color(0xD9000000);

// 3:4 portrait ratio
const double _kRatioValue = 3.0 / 4.0;
const String _kRatioLabel = '3:4';
const double _kScannerW = 200.0;
const double _kScannerH = 267.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  cameras = await availableCameras();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: _AuthGate()),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

Future<Directory> _getPhotosDir() async {
  Directory dcim = Directory('/storage/emulated/0/DCIM/SnapCam/Photos');

  if (!await dcim.exists()) {
    await dcim.create(recursive: true);
  }

  return dcim;
}

/// Crops [bytes] (JPEG) to [_kRatioValue] centred, returns PNG bytes.
/// Must be called on the main isolate (dart:ui requirement).
Future<Uint8List> _cropToRatio(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 2048);
  final frame = await codec.getNextFrame();
  final src = frame.image;

  final sw = src.width.toDouble();
  final sh = src.height.toDouble();

  double cropW = sw;
  double cropH = sw / _kRatioValue;
  if (cropH > sh) {
    cropH = sh;
    cropW = sh * _kRatioValue;
  }

  final left = (sw - cropW) / 2;
  final top = (sh - cropH) / 2;

  final rec = ui.PictureRecorder();
  final cvs = Canvas(rec);
  cvs.drawImageRect(
    src,
    Rect.fromLTWH(left, top, cropW, cropH),
    Rect.fromLTWH(0, 0, cropW, cropH),
    Paint()..filterQuality = FilterQuality.high,
  );
  final pic = rec.endRecording();
  final cropped = await pic.toImage(cropW.round(), cropH.round());
  src.dispose();

  final bd = await cropped.toByteData(format: ui.ImageByteFormat.png);
  cropped.dispose();
  if (bd == null) throw Exception('_cropToRatio: toByteData returned null');
  return bd.buffer.asUint8List();
}

// ═══════════════════════════════════════════════════════════════════════════════
// CAMERA PAGE
// ═══════════════════════════════════════════════════════════════════════════════
class CamPage extends StatefulWidget {
  const CamPage({super.key});
  @override
  State<CamPage> createState() => _CamState();
}

class _CamState extends State<CamPage> with TickerProviderStateMixin {
  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  int _camIdx = 0;
  bool _switching = false;

  bool get _isFront =>
      cameras.isNotEmpty &&
      _camIdx < cameras.length &&
      cameras[_camIdx].lensDirection == CameraLensDirection.front;

  // ── Flash ───────────────────────────────────────────────────────────────────
  static const _flashModes = [FlashMode.off, FlashMode.always, FlashMode.auto];
  int _fi = 0;
  FlashMode get _flash => _flashModes[_fi];

  IconData _flashIcon = Icons.flash_off_rounded;
  String _flashLabel = 'OFF';
  bool _flashActive = false;

  void _updateFlashCache() {
    _flashIcon = switch (_flash) {
      FlashMode.always => Icons.flash_on_rounded,
      FlashMode.auto => Icons.flash_auto_rounded,
      _ => Icons.flash_off_rounded,
    };
    _flashLabel = switch (_flash) {
      FlashMode.always => 'ON',
      FlashMode.auto => 'AUTO',
      _ => 'OFF',
    };
    _flashActive = _flash == FlashMode.always;
  }

  // ── Recording state ─────────────────────────────────────────────────────────
  bool _rec = false;
  bool _snapping = false; // true while stop→photo→restart is in progress
  bool _saving = false; // true while stitching/saving final video
  bool _flashWhite = false;
  int _secs = 0;
  int _photoCnt = 0;
  Timer? _timer;

  String _timeFmt = '00:00';
  int _timeFmtSecs = -1;

  String _getTime() {
    if (_secs == _timeFmtSecs) return _timeFmt;
    _timeFmtSecs = _secs;
    _timeFmt =
        '${(_secs ~/ 60).toString().padLeft(2, '0')}:'
        '${(_secs % 60).toString().padLeft(2, '0')}';
    return _timeFmt;
  }

  // ── Session data ────────────────────────────────────────────────────────────
  File? _lastPhoto;
  final _sessionPhotos = <File>[];
  String? _lastVideoPath;
  final _segs = <String>[];
  Directory? _photosDir; // cached after first use

  // ── Animations ──────────────────────────────────────────────────────────────
  late final _pulseC = _ac(1200);
  late final _shutC = _ac(120);
  late final _cntC = _ac(300);
  late final _flipC = _ac(400);
  late final _flashC = _ac(200);

  AnimationController _ac(int ms) => AnimationController(
    vsync: this,
    duration: Duration(milliseconds: ms),
  );

  late final Animation<double> _pulseA = Tween(
    begin: 0.85,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _pulseC, curve: Curves.easeInOut));
  late final Animation<double> _shutA = Tween(
    begin: 1.0,
    end: 0.88,
  ).animate(CurvedAnimation(parent: _shutC, curve: Curves.easeInOut));
  late final Animation<double> _flipA = Tween(
    begin: 0.0,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _flipC, curve: Curves.easeInOut));
  late final Animation<double> _cntA = _bounce(_cntC);
  late final Animation<double> _flashA = _bounce(_flashC, hi: 1.4);

  Animation<double> _bounce(AnimationController c, {double hi = 1.5}) =>
      TweenSequence([
        TweenSequenceItem(tween: Tween(begin: 1.0, end: hi), weight: 50),
        TweenSequenceItem(tween: Tween(begin: hi, end: 1.0), weight: 50),
      ]).animate(CurvedAnimation(parent: c, curve: Curves.elasticOut));

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initAll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    WakelockPlus.disable();
    _cam?.dispose();
    for (final c in [_pulseC, _shutC, _cntC, _flipC, _flashC]) c.dispose();
    super.dispose();
  }

  // ── Permissions & camera init ────────────────────────────────────────────────
  Future<void> _initAll() async {
    // Request core permissions. MANAGE_EXTERNAL_STORAGE is Android 11+ only
    // and restricted by Play Store — we request only what's needed.
    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage, // covers READ/WRITE_EXTERNAL_STORAGE on ≤ Android 9
    ].request();

    // On Android 10+ storage permission is auto-granted for app-specific dirs;
    // on Android 11+ we try manageExternalStorage for DCIM write access.
    if (Platform.isAndroid) {
      try {
        await Permission.manageExternalStorage.request();
      } catch (_) {
        // Permission doesn't exist on Android < 11 — safe to ignore.
      }
    }

    if (statuses[Permission.camera]?.isGranted != true) {
      debugPrint('Camera permission denied');
      return;
    }

    await _initCam(_camIdx);
  }

  Future<void> _initCam(int idx) async {
    if (idx >= cameras.length) return;
    final old = _cam;
    _cam = null;
    if (mounted) setState(() {});
    await old?.dispose();

    final c = CameraController(
      cameras[idx],
      ResolutionPreset.high,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await c.initialize();
      await c.setFlashMode(_flash);
      _cam = c;
    } catch (e) {
      debugPrint('Camera init error: $e');
      await c.dispose();
    }
    if (mounted) setState(() {});
  }

  // ── Camera controls ──────────────────────────────────────────────────────────
  Future<void> _toggleCam() async {
    if (_rec || _switching || cameras.length < 2) return;
    setState(() => _switching = true);
    _flipC.forward(from: 0);
    _camIdx = (_camIdx + 1) % cameras.length;
    await _initCam(_camIdx);
    if (_isFront && _flash != FlashMode.off) {
      _fi = 0;
      _updateFlashCache();
    }
    if (mounted) setState(() => _switching = false);
  }

  Future<void> _cycleFlash() async {
    if (_isFront) return;
    _flashC.forward(from: 0);
    _fi = (_fi + 1) % _flashModes.length;
    _updateFlashCache();
    setState(() {});
    try {
      await _cam?.setFlashMode(_flash);
    } catch (e) {
      debugPrint('Flash error: $e');
    }
  }

  // ── Logout ────────────────────────────────────────────────────────────────────
  Future<void> _logout() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _LogoutSheet(),
    );
    if (confirmed != true || !mounted) return;
    if (_rec) await _stopRec();
    if (!mounted) return;
    await Auth.logOut();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginPage(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  // ── Recording ─────────────────────────────────────────────────────────────────
  Future<void> _startRec() async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized || cam.value.isRecordingVideo)
      return;

    // Verify microphone permission before attempting to record.
    if (!await Permission.microphone.isGranted) {
      final s = await Permission.microphone.request();
      if (!s.isGranted) {
        debugPrint('Microphone permission denied — cannot record video');
        return;
      }
    }

    _segs.clear();
    _sessionPhotos.clear();
    _lastVideoPath = null;

    try {
      await cam.startVideoRecording();
    } catch (e) {
      debugPrint('Start recording error: $e');
      return;
    }

    await WakelockPlus.enable();
    _pulseC.repeat(reverse: true);
    setState(() {
      _rec = true;
      _secs = 0;
      _photoCnt = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _secs++);
    });
  }

  Future<void> _stopRec() async {
    final cam = _cam;
    if (cam == null || !cam.value.isRecordingVideo) return;

    _timer?.cancel();
    _timer = null;
    await WakelockPlus.disable();
    _pulseC
      ..stop()
      ..reset();

    XFile? videoFile;
    try {
      videoFile = await cam.stopVideoRecording();
    } catch (e) {
      debugPrint('Stop recording error: $e');
    }
    if (videoFile != null) _segs.add(videoFile.path);

    setState(() {
      _rec = false;
      _secs = 0;
      _photoCnt = 0;
      _saving = true;
    });

    try {
      if (_segs.isNotEmpty) {
        final out = await _stitch(_segs);
        await _ch.invokeMethod('saveVideoToGallery', {
          'path': out,
          'ratio': _kRatioLabel,
        });
        if (mounted) setState(() => _lastVideoPath = out);
      }
    } catch (e) {
      debugPrint('Save video error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
      _segs.clear();
    }
  }

  Future<String> _stitch(List<String> segs) async {
    if (segs.length == 1) return segs.first;
    final tmp = await getTemporaryDirectory();
    final out = p.join(
      tmp.path,
      'sc_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );
    await _ch.invokeMethod('stitchVideos', {'segments': segs, 'output': out});
    return out;
  }

  // ── Photo snap ────────────────────────────────────────────────────────────────
  //
  // APPROACH: stop video → takePicture → restart video.
  //
  // WHY: The Flutter camera plugin on Android uses camera2 API. On devices with
  // LEGACY hardware level (very common on budget/mid-range Android phones),
  // calling takePicture() while isRecordingVideo=true throws:
  //   "takePicture called while video is recording"
  // The only universally-reliable approach is to briefly pause the recording
  // segment, capture the still, then immediately resume a new segment.
  // The segments are stitched together when the user stops recording.
  //
  // The brief gap (~300 ms) is imperceptible in the final stitched video.
  Future<void> _snap() async {
    final cam = _cam;
    if (cam == null ||
        !cam.value.isInitialized ||
        !cam.value.isRecordingVideo ||
        _snapping)
      return;

    setState(() => _snapping = true);
    _shutC.forward().then((_) => _shutC.reverse());

    XFile? imgFile;

    try {
      // ① Stop current video segment and save it.
      final seg = await cam.stopVideoRecording();
      _segs.add(seg.path);

      // ② Capture still image (camera is now in preview mode).
      imgFile = await cam.takePicture();

      // ③ Restart video recording immediately.
      await cam.startVideoRecording();
    } catch (e) {
      debugPrint('Snap error: $e');
      // If recording stopped but failed to restart, attempt recovery.
      try {
        final c = _cam;
        if (c != null && c.value.isInitialized && !c.value.isRecordingVideo) {
          await c.startVideoRecording();
        }
      } catch (e2) {
        debugPrint('Recording restart error: $e2');
      }
    } finally {
      if (mounted) setState(() => _snapping = false);
    }

    // ④ Save photo after recording has restarted (never blocks recording).
    if (imgFile != null) {
      _triggerFlash();
      _cntC.forward(from: 0);
      unawaited(_savePhoto(imgFile.path));
    }
  }

  void _triggerFlash() {
    if (!mounted) return;
    setState(() => _flashWhite = true);
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted) setState(() => _flashWhite = false);
    });
  }

  // ── Photo save ────────────────────────────────────────────────────────────────
  //
  // Strategy:
  //   1. FAST PATH — copy the raw JPEG from camera directly to DCIM folder.
  //      The camera already produces a high-quality JPEG; no re-encoding needed.
  //      This is instant (~5 ms) and never blocks the UI.
  //   2. CROP PATH — after the fast copy, if the raw image is not 3:4, we crop
  //      and overwrite. The crop uses dart:ui on the main isolate.
  //      We update the UI thumbnail BEFORE the crop so it appears immediately.
  //
  // NOTE: dart:ui Canvas/Image APIs are UI-thread-only and CANNOT run in a
  // background Isolate. Using Isolate.run() with dart:ui crashes silently.
  Future<void> _savePhoto(String srcPath) async {
    try {
      // Resolve and cache the photos directory.
      _photosDir ??= await _getPhotosDir();
      final dir = _photosDir!;
      final dest = p.join(
        dir.path,
        'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      // ── Step 1: fast copy raw JPEG ──────────────────────────────────────
      await File(srcPath).copy(dest);
      await _scanFile(dest);

      // Update UI immediately with the raw photo so thumbnail appears fast.
      if (mounted) {
        setState(() {
          _lastPhoto = File(dest);
          _sessionPhotos.add(File(dest));
          _photoCnt++;
        });
      }

      // ── Step 2: crop to 3:4 and overwrite (on main isolate) ────────────
      try {
        final raw = await File(dest).readAsBytes();
        final cropped = await _cropToRatio(raw);
        // Save as PNG (dart:ui produces PNG; rename extension accordingly).
        // Gallery apps use magic bytes not extension on Android — PNG works fine.
        final pngDest = dest.replaceAll('.jpg', '.png');
        await File(pngDest).writeAsBytes(cropped, flush: true);
        // Remove the temporary raw .jpg if the .png was written successfully.
        await File(dest).delete();

        // Update the reference to point to the cropped PNG.
        if (mounted) {
          setState(() {
            final idx = _sessionPhotos.indexWhere((f) => f.path == dest);
            if (idx >= 0) _sessionPhotos[idx] = File(pngDest);
            if (_lastPhoto?.path == dest) _lastPhoto = File(pngDest);
          });
        }

        // Scan the final PNG into MediaStore.
        await _scanFile(pngDest);
      } catch (cropErr) {
        // Crop failed — keep the raw JPEG. Still scan it.
        debugPrint('Crop failed (using raw JPEG): $cropErr');
        await _scanFile(dest);
      }
    } catch (e) {
      debugPrint('SavePhoto error: $e');
    }
  }

  Future<void> _scanFile(String path) async {
    try {
      await _ch.invokeMethod('scanFile', {'path': path});
    } catch (e) {
      debugPrint('MediaStore scan error (non-fatal): $e');
    }
  }

  // ── Gallery ───────────────────────────────────────────────────────────────────
  void _openGallery() {
    if (_sessionPhotos.isEmpty && _lastVideoPath == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GallerySheet(
        photos: List.from(_sessionPhotos),
        videoPath: _lastVideoPath,
      ),
    );
  }

  Widget _sw(int ms, Widget child) => AnimatedSwitcher(
    duration: Duration(milliseconds: ms),
    child: child,
  );

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            color: Colors.white24,
            strokeWidth: 1,
          ),
        ),
      );
    }

    final previewSize = cam.value.previewSize;
    if (previewSize == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            color: Colors.white24,
            strokeWidth: 1,
          ),
        ),
      );
    }

    final mq = MediaQuery.of(context);
    final top = mq.padding.top;
    final h = mq.size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 1. Camera preview ──────────────────────────────────────────
            RepaintBoundary(
              child: SizedBox.expand(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _kRatioValue,
                    child: ClipRect(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        // previewSize is in landscape (sensor) orientation;
                        // swap width/height for portrait display.
                        child: SizedBox(
                          width: previewSize.height,
                          height: previewSize.width,
                          child: CameraPreview(cam),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── 2. Top gradient ────────────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: h * 0.22,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xCC000000), Colors.transparent],
                  ),
                ),
              ),
            ),

            // ── 3. Bottom gradient ─────────────────────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: h * 0.35,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xEE000000), Colors.transparent],
                  ),
                ),
              ),
            ),

            // ── 4. Shutter flash overlay ────────────────────────────────────
            if (_flashWhite)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0xBFFFFFFF)),
                ),
              ),

            // ── 5. Scanner frame ────────────────────────────────────────────
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _ScannerFrame(width: _kScannerW, height: _kScannerH),
                ),
              ),
            ),

            // ── 6. "Saving…" overlay ────────────────────────────────────────
            if (_saving)
              const Positioned.fill(
                child: ColoredBox(
                  color: _kBlack72,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            color: Colors.white70,
                            strokeWidth: 1.5,
                          ),
                        ),
                        SizedBox(height: 20),
                        Text(
                          'COMPRESSING & SAVING',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── 7. Top bar ──────────────────────────────────────────────────
            Positioned(
              top: top + 16,
              left: 24,
              right: 24,
              child: RepaintBoundary(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Left: timer badge while recording / logout button otherwise
                    _sw(
                      300,
                      _rec
                          ? _RecBadge(
                              key: const ValueKey('r'),
                              anim: _pulseA,
                              time: _getTime(),
                            )
                          : GestureDetector(
                              key: const ValueKey('i'),
                              onTap: _logout,
                              child: SizedBox(
                                width: 80,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: const Color(0x26FFFFFF),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: const Color(0x33FFFFFF),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.logout_rounded,
                                      color: Colors.white60,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),

                    // Centre: flash button (hidden while recording)
                    _sw(
                      250,
                      !_rec
                          ? _FlashBtn(
                              key: const ValueKey('f'),
                              icon: _flashIcon,
                              label: _flashLabel,
                              active: _flashActive,
                              disabled: _isFront,
                              scale: _flashA,
                              onTap: _cycleFlash,
                            )
                          : const SizedBox(key: ValueKey('nf'), width: 60),
                    ),

                    // Right: photo-count badge while recording / empty otherwise
                    _sw(
                      300,
                      _rec
                          ? ScaleTransition(
                              key: const ValueKey('c'),
                              scale: _cntA,
                              child: _CntBadge(count: _photoCnt),
                            )
                          : const SizedBox(key: ValueKey('nc'), width: 60),
                    ),
                  ],
                ),
              ),
            ),

            // ── 8. Bottom controls ──────────────────────────────────────────
            Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Gallery thumbnail
                      _Thumb(file: _lastPhoto, onTap: _openGallery),

                      // Record / stop button
                      _RecBtn(
                        rec: _rec,
                        anim: _pulseA,
                        onTap: _rec ? _stopRec : _startRec,
                      ),

                      // Snap button (recording) / flip button (idle)
                      _sw(
                        200,
                        _rec
                            ? ScaleTransition(
                                key: const ValueKey('s'),
                                scale: _shutA,
                                child: _SnapBtn(
                                  enabled: !_snapping,
                                  onTap: _snap,
                                ),
                              )
                            : _FlipBtn(
                                key: const ValueKey('fl'),
                                anim: _flipA,
                                isFront: _isFront,
                                enabled: !_switching && cameras.length >= 2,
                                onTap: _toggleCam,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// FLASH BUTTON
// ═══════════════════════════════════════════════════════════════════════════════
class _FlashBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active, disabled;
  final Animation<double> scale;
  final VoidCallback onTap;

  const _FlashBtn({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.disabled,
    required this.scale,
    required this.onTap,
  });

  static const _decoActive = BoxDecoration(
    color: Color(0x26FFD60A),
    borderRadius: BorderRadius.all(Radius.circular(30)),
    border: Border.fromBorderSide(
      BorderSide(color: Color(0x99FFD60A), width: 0.8),
    ),
  );
  static const _decoIdle = BoxDecoration(
    color: _kBlack45,
    borderRadius: BorderRadius.all(Radius.circular(30)),
    border: Border.fromBorderSide(BorderSide(color: _kWhite20, width: 0.8)),
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: disabled ? null : onTap,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: disabled ? 0.25 : 1.0,
      child: ScaleTransition(
        scale: scale,
        child: DecoratedBox(
          decoration: active ? _decoActive : _decoIdle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: active ? _kYellow : Colors.white),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: active ? _kYellow : Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORDING BADGE (timer + pulsing red dot)
// ═══════════════════════════════════════════════════════════════════════════════
class _RecBadge extends StatelessWidget {
  final Animation<double> anim;
  final String time;
  const _RecBadge({super.key, required this.anim, required this.time});

  static const _deco = BoxDecoration(
    color: _kBlack50,
    borderRadius: BorderRadius.all(Radius.circular(30)),
    border: Border.fromBorderSide(
      BorderSide(color: Color(0x1FFFFFFF), width: 0.5),
    ),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: _deco,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: anim,
            builder: (_, child) =>
                Transform.scale(scale: anim.value, child: child),
            child: const _RedDot(),
          ),
          const SizedBox(width: 8),
          Text(
            time,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    ),
  );
}

class _RedDot extends StatelessWidget {
  const _RedDot();
  static const _deco = BoxDecoration(
    color: _kRed,
    shape: BoxShape.circle,
    boxShadow: [BoxShadow(color: _kRedGlow, blurRadius: 6, spreadRadius: 1)],
  );
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 7,
    height: 7,
    child: DecoratedBox(decoration: _deco),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// PHOTO COUNT BADGE
// ═══════════════════════════════════════════════════════════════════════════════
class _CntBadge extends StatelessWidget {
  final int count;
  const _CntBadge({super.key, required this.count});

  static const _decoActive = BoxDecoration(
    color: _kRed,
    borderRadius: BorderRadius.all(Radius.circular(30)),
    boxShadow: [BoxShadow(color: _kRedShadow, blurRadius: 10, spreadRadius: 1)],
  );
  static const _decoIdle = BoxDecoration(
    color: _kBlack54,
    borderRadius: BorderRadius.all(Radius.circular(30)),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: count > 0 ? _decoActive : _decoIdle,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_camera, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            '$count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// GALLERY THUMBNAIL (bottom-left corner)
// ═══════════════════════════════════════════════════════════════════════════════
class _Thumb extends StatelessWidget {
  final File? file;
  final VoidCallback onTap;
  const _Thumb({required this.file, required this.onTap});

  static const _deco = BoxDecoration(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    border: Border.fromBorderSide(BorderSide(color: _kWhite30, width: 1)),
    color: _kWhite12,
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: SizedBox(
      width: 54,
      height: 54,
      child: DecoratedBox(
        decoration: _deco,
        child: file != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.file(file!, fit: BoxFit.cover, cacheWidth: 108),
              )
            : const Center(
                child: Icon(Icons.photo_outlined, color: _kWhite40, size: 22),
              ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORD BUTTON (centre)
// ═══════════════════════════════════════════════════════════════════════════════
class _RecBtn extends StatelessWidget {
  final bool rec;
  final VoidCallback onTap;
  final Animation<double> anim;
  const _RecBtn({required this.rec, required this.onTap, required this.anim});

  static const _ringIdle = BoxDecoration(
    shape: BoxShape.circle,
    border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 2.5)),
  );
  static const _ringRec = BoxDecoration(
    shape: BoxShape.circle,
    border: Border.fromBorderSide(BorderSide(color: _kWhite40, width: 2.5)),
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedBuilder(
      animation: anim,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: rec ? 26 : 58,
        height: rec ? 26 : 58,
        decoration: BoxDecoration(
          color: rec ? _kRed : Colors.white,
          borderRadius: BorderRadius.circular(rec ? 6 : 29),
        ),
      ),
      builder: (_, child) => Stack(
        alignment: Alignment.center,
        children: [
          if (rec)
            Transform.scale(
              scale: anim.value * 1.15,
              child: SizedBox(
                width: 86,
                height: 86,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Color.fromARGB(
                        (0.25 * anim.value * 255).round(),
                        255,
                        59,
                        48,
                      ),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 78,
            height: 78,
            child: DecoratedBox(decoration: rec ? _ringRec : _ringIdle),
          ),
          child!,
        ],
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// SHUTTER / SNAP BUTTON
// ═══════════════════════════════════════════════════════════════════════════════
class _SnapBtn extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _SnapBtn({super.key, required this.enabled, required this.onTap});

  static const _outerOn = BoxDecoration(
    shape: BoxShape.circle,
    color: _kWhite12,
    border: Border.fromBorderSide(BorderSide(color: _kWhite60, width: 1)),
  );
  static const _outerOff = BoxDecoration(
    shape: BoxShape.circle,
    color: _kWhite12,
    border: Border.fromBorderSide(BorderSide(color: _kWhite20, width: 1)),
  );
  static const _innerOn = BoxDecoration(
    shape: BoxShape.circle,
    color: _kWhite90,
  );
  static const _innerOff = BoxDecoration(
    shape: BoxShape.circle,
    color: _kWhite30,
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: enabled ? 1.0 : 0.25,
      child: SizedBox(
        width: 54,
        height: 54,
        child: DecoratedBox(
          decoration: enabled ? _outerOn : _outerOff,
          child: Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: DecoratedBox(
                decoration: enabled ? _innerOn : _innerOff,
                child: Icon(
                  Icons.camera_alt_outlined,
                  size: 16,
                  color: enabled ? _kBlack85 : _kBlack45,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// FLIP CAMERA BUTTON
// ═══════════════════════════════════════════════════════════════════════════════
class _FlipBtn extends StatelessWidget {
  final Animation<double> anim;
  final bool isFront, enabled;
  final VoidCallback onTap;
  const _FlipBtn({
    super.key,
    required this.anim,
    required this.isFront,
    required this.enabled,
    required this.onTap,
  });

  static const _deco = BoxDecoration(
    shape: BoxShape.circle,
    color: _kWhite12,
    border: Border.fromBorderSide(BorderSide(color: _kWhite40, width: 1)),
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1.0 : 0.3,
      child: SizedBox(
        width: 54,
        height: 54,
        child: DecoratedBox(
          decoration: _deco,
          child: Center(
            child: AnimatedBuilder(
              animation: anim,
              child: Icon(
                isFront
                    ? Icons.camera_front_outlined
                    : Icons.camera_rear_outlined,
                size: 22,
                color: _kWhite90,
              ),
              builder: (_, child) => Transform.rotate(
                angle: anim.value * 2 * math.pi,
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// SCANNER FRAME
// ═══════════════════════════════════════════════════════════════════════════════
class _ScannerFrame extends StatelessWidget {
  final double width, height;
  const _ScannerFrame({required this.width, required this.height});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(width, height), painter: _ScannerPainter());
}

class _ScannerPainter extends CustomPainter {
  static final _p = Paint()
    ..color = Colors.white
    ..strokeWidth = 3.5
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size sz) {
    final arm = math.min(sz.width, sz.height) * 0.18;
    const r = 10.0;
    final w = sz.width, h = sz.height;

    void corner(
      double ax,
      double ay,
      double angle,
      Offset a,
      Offset b,
      Offset c,
      Offset d,
    ) {
      canvas.drawLine(a, b, _p);
      canvas.drawLine(c, d, _p);
      canvas.drawArc(
        Rect.fromLTWH(ax, ay, r * 2, r * 2),
        angle,
        math.pi / 2,
        false,
        _p,
      );
    }

    corner(
      0,
      0,
      math.pi,
      Offset(r, 0),
      Offset(arm, 0),
      Offset(0, r),
      Offset(0, arm),
    );
    corner(
      w - r * 2,
      0,
      math.pi * 1.5,
      Offset(w - arm, 0),
      Offset(w - r, 0),
      Offset(w, r),
      Offset(w, arm),
    );
    corner(
      0,
      h - r * 2,
      math.pi / 2,
      Offset(0, h - arm),
      Offset(0, h - r),
      Offset(r, h),
      Offset(arm, h),
    );
    corner(
      w - r * 2,
      h - r * 2,
      0,
      Offset(w, h - arm),
      Offset(w, h - r),
      Offset(w - arm, h),
      Offset(w - r, h),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// GALLERY BOTTOM SHEET
// ═══════════════════════════════════════════════════════════════════════════════
class _GallerySheet extends StatefulWidget {
  final List<File> photos;
  final String? videoPath;
  const _GallerySheet({required this.photos, required this.videoPath});
  @override
  State<_GallerySheet> createState() => _GallerySheetState();
}

class _GallerySheetState extends State<_GallerySheet> {
  int _sel = 0;

  bool get _hasVid => widget.videoPath != null;
  int get _total => (_hasVid ? 1 : 0) + widget.photos.length;
  bool _isVid(int i) => _hasVid && i == 0;
  String _label(int i) => _isVid(i) ? 'VIDEO' : 'PHOTO ${_hasVid ? i : i + 1}';

  /// Safe thumbnail lookup — never throws RangeError.
  File? _thumb(int i) {
    if (_hasVid) {
      if (i == 0) return widget.photos.isNotEmpty ? widget.photos.first : null;
      final idx = i - 1;
      return idx < widget.photos.length ? widget.photos[idx] : null;
    }
    return i < widget.photos.length ? widget.photos[i] : null;
  }

  /// Safe photo lookup — returns null instead of throwing.
  File? _photoAt(int i) {
    if (_hasVid) {
      final idx = i - 1;
      return (idx >= 0 && idx < widget.photos.length)
          ? widget.photos[idx]
          : null;
    }
    return i < widget.photos.length ? widget.photos[i] : null;
  }

  Future<void> _open() async {
    if (_isVid(_sel)) {
      final path = widget.videoPath;
      if (path != null) await OpenFilex.open(path);
    } else {
      final file = _photoAt(_sel);
      if (file != null) await OpenFilex.open(file.path);
    }
  }

  static const _sheetDeco = BoxDecoration(
    color: Color(0xFF111111),
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
  );
  static const _handleDeco = BoxDecoration(
    color: Colors.white24,
    borderRadius: BorderRadius.all(Radius.circular(2)),
  );
  static const _playDeco = BoxDecoration(
    color: _kBlack50,
    shape: BoxShape.circle,
    border: Border.fromBorderSide(
      BorderSide(color: Colors.white54, width: 1.5),
    ),
  );
  static const _hintDeco = BoxDecoration(
    color: _kBlack50,
    borderRadius: BorderRadius.all(Radius.circular(20)),
  );

  @override
  Widget build(BuildContext context) {
    final n = widget.photos.length;
    final maxSel = math.max(0, _total - 1);
    if (_sel > maxSel) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _sel = maxSel);
      });
    }

    final photo = _photoAt(_sel);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: DecoratedBox(
        decoration: _sheetDeco,
        child: Column(
          children: [
            const SizedBox(height: 12),
            const SizedBox(
              width: 40,
              height: 4,
              child: DecoratedBox(decoration: _handleDeco),
            ),
            const SizedBox(height: 12),

            // Header row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'SESSION  ·  $n ${n == 1 ? 'PHOTO' : 'PHOTOS'}'
                    '${_hasVid ? '  +  VIDEO' : ''}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white38,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Main preview
            Expanded(
              child: GestureDetector(
                onTap: _open,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Photo preview
                    if (!_isVid(_sel) && photo != null)
                      Positioned.fill(
                        child: Image.file(photo, fit: BoxFit.contain),
                      ),

                    // Video preview (blurred first-frame thumbnail)
                    if (_isVid(_sel))
                      Positioned.fill(
                        child: widget.photos.isNotEmpty
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(
                                    widget.photos.first,
                                    fit: BoxFit.contain,
                                  ),
                                  const ColoredBox(color: _kBlack45),
                                ],
                              )
                            : const ColoredBox(color: _kBlack54),
                      ),

                    // Play icon
                    if (_isVid(_sel))
                      const SizedBox(
                        width: 64,
                        height: 64,
                        child: DecoratedBox(
                          decoration: _playDeco,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      ),

                    // "Tap to open" hint
                    Positioned(
                      bottom: 12,
                      child: DecoratedBox(
                        decoration: _hintDeco,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.open_in_new,
                                size: 11,
                                color: Colors.white54,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'TAP TO OPEN  ·  ${_label(_sel)}',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 10,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Thumbnail strip
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                itemCount: _total,
                itemBuilder: (_, i) {
                  final sel = i == _sel;
                  final thumb = _thumb(i);
                  return GestureDetector(
                    onTap: () => setState(() => _sel = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 56,
                      height: 56,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: sel ? _kRed : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (thumb != null)
                              Image.file(
                                thumb,
                                fit: BoxFit.cover,
                                cacheWidth: 112,
                              )
                            else
                              const ColoredBox(color: Color(0x1AFFFFFF)),
                            if (_isVid(i))
                              const ColoredBox(
                                color: _kBlack45,
                                child: Center(
                                  child: Icon(
                                    Icons.videocam_rounded,
                                    color: Colors.white70,
                                    size: 20,
                                  ),
                                ),
                              ),
                            if (!sel)
                              const ColoredBox(color: Color(0x61000000)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// AUTH GATE
// ═══════════════════════════════════════════════════════════════════════════════
class _AuthGate extends StatefulWidget {
  const _AuthGate();
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final user = await Auth.currentUser();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => user != null ? const CamPage() : const LoginPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Color(0xFF0A0A0A),
    body: Center(
      child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 1),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// LOGOUT SHEET
// ═══════════════════════════════════════════════════════════════════════════════
class _LogoutSheet extends StatelessWidget {
  const _LogoutSheet();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      20,
      24,
      MediaQuery.of(context).padding.bottom + 24,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0x26FF3B30),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x55FF3B30), width: 1),
          ),
          child: const Icon(
            Icons.logout_rounded,
            color: Color(0xFFFF3B30),
            size: 22,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Sign out?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Your saved photos and videos will stay on the device.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white54,
            fontSize: 13,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.1,
          ),
        ),
        const SizedBox(height: 28),

        // Sign out button
        GestureDetector(
          onTap: () => Navigator.pop(context, true),
          child: Container(
            height: 52,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55FF3B30),
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Center(
              child: Text(
                'SIGN OUT',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.8,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Cancel button
        GestureDetector(
          onTap: () => Navigator.pop(context, false),
          child: Container(
            height: 52,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
            ),
            child: const Center(
              child: Text(
                'CANCEL',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 1.8,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

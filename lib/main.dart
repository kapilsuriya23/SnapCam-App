import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// GLOBALS & COMPILE-TIME CONSTANTS
// Every color/decoration that is the same across the lifetime of the app lives
// here as a top-level const so it is allocated exactly once in the Dart heap,
// never copied, and never garbage-collected.
// ═══════════════════════════════════════════════════════════════════════════════
late List<CameraDescription> cameras;
const _ch = MethodChannel('com.example.app/media_store');
const _photosPath = '/storage/emulated/0/DCIM/SnapCam/Photos';

// Brand colours
const _kRed = Color(0xFFFF3B30);
const _kYellow = Color(0xFFFFD60A);

// Pre-baked alpha variants — withValues() is never called at runtime
const _kRedGlow = Color(0x99FF3B30); // red  @ 60 %
const _kRedShadow = Color(0x80FF3B30); // red  @ 50 %
const _kRedPulse = Color(0x40FF3B30); // red  @ 25 % (pulse ring max)
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock orientation once — never recalculated
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  cameras = await availableCameras();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: _CamPage()),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// CAMERA PAGE
// ═══════════════════════════════════════════════════════════════════════════════
class _CamPage extends StatefulWidget {
  const _CamPage();
  @override
  State<_CamPage> createState() => _CamState();
}

class _CamState extends State<_CamPage> with TickerProviderStateMixin {
  // ── Camera ──────────────────────────────────────────────────────────────────
  CameraController? _cam;
  int _camIdx = 0;
  bool _switching = false;
  bool get _isFront =>
      cameras.isNotEmpty &&
      _camIdx < cameras.length &&
      cameras[_camIdx].lensDirection == CameraLensDirection.front;

  // ── Flash ────────────────────────────────────────────────────────────────────
  static const _flashModes = [FlashMode.off, FlashMode.always, FlashMode.auto];
  int _fi = 0;
  FlashMode get _flash => _flashModes[_fi];

  // Flash icon/label cached — recomputed only in _updateFlashCache(), never in build()
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

  // ── Recording state ──────────────────────────────────────────────────────────
  bool _rec = false;
  bool _snapping = false;
  bool _saving = false;
  bool _flashWhite = false;
  int _secs = 0;
  int _photoCnt = 0;
  Timer? _timer;

  // Timer display — memoised so String allocation happens once per second,
  // not on every build() call
  String _timeFmt = '00:00';
  int _timeFmtSecs = -1;
  String _getTime() {
    if (_secs == _timeFmtSecs) return _timeFmt;
    _timeFmtSecs = _secs;
    _timeFmt =
        '${(_secs ~/ 60).toString().padLeft(2, '0')}:${(_secs % 60).toString().padLeft(2, '0')}';
    return _timeFmt;
  }

  // ── Session ──────────────────────────────────────────────────────────────────
  File? _lastPhoto;
  final _sessionPhotos = <File>[];
  String? _lastVideoPath;
  final _segs = <String>[];

  // ── Animations ───────────────────────────────────────────────────────────────
  // All controllers created with the same helper; none start until needed.
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
    WakelockPlus.disable();
    _cam?.dispose();
    for (final c in [_pulseC, _shutC, _cntC, _flipC, _flashC]) c.dispose();
    super.dispose();
  }

  // ── Init ─────────────────────────────────────────────────────────────────────
  Future<void> _initAll() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.photos,
      Permission.videos,
    ].request();
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
    await c.initialize();
    await c.setFlashMode(_flash);
    _cam = c;
    if (mounted) setState(() {});
  }

  // ── Camera controls ───────────────────────────────────────────────────────────
  Future<void> _toggleCam() async {
    if (_rec || _switching || cameras.length < 2) return;
    setState(() => _switching = true);
    _flipC.forward(from: 0);
    _camIdx = _camIdx == 0 ? 1 : 0;
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
    _updateFlashCache(); // update cache before setState triggers build
    setState(() {});
    try {
      await _cam?.setFlashMode(_flash);
    } catch (_) {}
  }

  // ── Recording ─────────────────────────────────────────────────────────────────
  Future<void> _startRec() async {
    if (_cam == null || _cam!.value.isRecordingVideo) return;
    _segs.clear();
    _sessionPhotos.clear();
    _lastVideoPath = null;
    await _cam!.startVideoRecording();
    await WakelockPlus.enable();
    _pulseC.repeat(reverse: true);
    setState(() {
      _rec = true;
      _secs = 0;
      _photoCnt = 0;
    });
    // Timer setState is deliberately minimal: only _secs changes each tick.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _secs++);
    });
  }

  Future<void> _stopRec() async {
    if (_cam == null || !_cam!.value.isRecordingVideo) return;
    _timer?.cancel();
    await WakelockPlus.disable();
    _pulseC
      ..stop()
      ..reset();
    _segs.add((await _cam!.stopVideoRecording()).path);
    setState(() {
      _rec = false;
      _secs = 0;
      _photoCnt = 0;
      _saving = true;
    });
    try {
      final out = await _stitch(_segs);
      await _ch.invokeMethod('saveVideoToGallery', {'path': out});
      if (mounted) setState(() => _lastVideoPath = out);
    } catch (e) {
      debugPrint('Save: $e');
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

  // ── Photo ─────────────────────────────────────────────────────────────────────
  Future<void> _snap() async {
    if (_cam == null ||
        !_cam!.value.isRecordingVideo ||
        _cam!.value.isTakingPicture ||
        _snapping)
      return;
    setState(() => _snapping = true);
    _shutC.forward().then((_) => _shutC.reverse());
    try {
      _segs.add((await _cam!.stopVideoRecording()).path);
      final img = await _cam!.takePicture();
      setState(() => _flashWhite = true);
      await Future.delayed(const Duration(milliseconds: 80));
      if (mounted) setState(() => _flashWhite = false);
      await _savePhoto(img.path);
      _cntC.forward(from: 0);
      await _cam!.startVideoRecording();
    } catch (e) {
      debugPrint('Snap: $e');
    } finally {
      if (mounted) setState(() => _snapping = false);
    }
  }

  Future<void> _savePhoto(String src) async {
    try {
      final d = Directory(_photosPath);
      if (!await d.exists()) await d.create(recursive: true);
      final ext = p.extension(src).isNotEmpty ? p.extension(src) : '.jpg';
      final dest = p.join(
        d.path,
        'IMG_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await File(src).copy(dest);
      await _ch.invokeMethod('scanFile', {'path': dest});
      if (mounted)
        setState(() {
          _lastPhoto = File(dest);
          _sessionPhotos.add(File(dest));
          _photoCnt++;
        });
    } catch (e) {
      debugPrint('SavePhoto: $e');
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

  // ── AnimatedSwitcher helper ───────────────────────────────────────────────────
  // Defined as an inline helper (not a member widget) so no extra class overhead.
  Widget _sw(int ms, Widget child) => AnimatedSwitcher(
    duration: Duration(milliseconds: ms),
    child: child,
  );

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_cam == null || !_cam!.value.isInitialized) {
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

    // Read MediaQuery once — avoids multiple O(n) lookups through the tree.
    final mq = MediaQuery.of(context);
    final top = mq.padding.top;
    final h = mq.size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: RepaintBoundary(
        // Outer boundary: top-level isolation. Nothing outside the camera
        // UI can ever trigger a repaint of this subtree.
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 1. Camera preview ──────────────────────────────────────
            // Inner RepaintBoundary: the 30 fps texture updates coming from
            // CameraPreview are fully contained here — they never dirty the
            // widget layers above (gradients, badges, buttons).
            RepaintBoundary(
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _cam!.value.previewSize!.height,
                    height: _cam!.value.previewSize!.width,
                    child: CameraPreview(_cam!),
                  ),
                ),
              ),
            ),

            // ── 2. Gradient overlays ───────────────────────────────────
            // const DecoratedBox: zero heap allocation on every build pass.
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

            // ── 3. Photo-flash white overlay ───────────────────────────
            // Only inserted into the widget tree for ~80 ms; const color
            // avoids any runtime Color construction.
            if (_flashWhite)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0xBFFFFFFF)),
                ),
              ),

            // ── 4. Scanner frame ───────────────────────────────────────
            // const all the way down — never repainted, never rebuilt.
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(child: _ScannerFrame(size: 220)),
              ),
            ),

            // ── 5. Saving overlay ──────────────────────────────────────
            // Only in tree while _saving == true. Inner widgets are const
            // so Flutter reuses them without allocation.
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

            // ── 6. Top bar ─────────────────────────────────────────────
            // Isolated in its own RepaintBoundary so the 1-second timer tick
            // only repaints this region (~80×24 dp), not the entire screen.
            Positioned(
              top: top + 16,
              left: 24,
              right: 24,
              child: RepaintBoundary(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _sw(
                      300,
                      _rec
                          ? _RecBadge(
                              key: const ValueKey('r'),
                              anim: _pulseA,
                              time: _getTime(),
                            )
                          : const SizedBox(key: ValueKey('i'), width: 80),
                    ),

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

            // ── 7. Bottom controls ─────────────────────────────────────
            // Isolated in its own RepaintBoundary so button animations
            // (flip spin, shutter scale) never dirty the top bar or preview.
            Positioned(
              bottom: 36,
              left: 0,
              right: 0,
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _Thumb(file: _lastPhoto, onTap: _openGallery),

                      _RecBtn(
                        rec: _rec,
                        anim: _pulseA,
                        onTap: _rec ? _stopRec : _startRec,
                      ),

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
// ScaleTransition animates at 60 fps only during the 200 ms pop; decoration is
// pre-baked into two static const instances so no allocation happens in build().
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

  // Pre-baked decorations — chosen in build() with zero allocation.
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
  Widget build(BuildContext context) {
    final clr = active ? _kYellow : Colors.white;
    final deco = active ? _decoActive : _decoIdle;
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: disabled ? 0.25 : 1.0,
        child: ScaleTransition(
          scale: scale,
          child: DecoratedBox(
            decoration: deco,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: clr),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: clr,
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
}

// ═══════════════════════════════════════════════════════════════════════════════
// RECORDING BADGE
// The pulsing dot is wrapped in a tight AnimatedBuilder so only a 7×7 dp region
// repaints at 60 fps.  The pill container and the timer text live outside the
// builder — they are rebuilt only on the 1-second setState.
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
            // _RedDot is const — its build() is never called inside the builder;
            // only Transform.scale is re-evaluated at 60 fps.
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

// Separated so the full BoxDecoration+BoxShadow subtree is built once (const)
// and the widget reference is simply reused every frame.
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
// Two static const decorations cover both states; the active one includes a
// pre-baked const BoxShadow list so no list allocation occurs during animation.
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
// GALLERY THUMBNAIL
// Empty state uses a static const decoration; filled state allocates one
// BoxDecoration only when a new photo is saved (file reference changes).
// ═══════════════════════════════════════════════════════════════════════════════
class _Thumb extends StatelessWidget {
  final File? file;
  final VoidCallback onTap;
  const _Thumb({required this.file, required this.onTap});

  static const _decoEmpty = BoxDecoration(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    border: Border.fromBorderSide(BorderSide(color: _kWhite30, width: 1)),
    color: _kWhite12,
  );

  static const _decoFilled = BoxDecoration(
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
        decoration: file != null ? _decoFilled : _decoEmpty,
        child: file != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(11),
                // cacheWidth=108: decode at 2× display size (54 dp logical),
                // avoids uploading a full 12 MP texture to the GPU every rebuild.
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
// RECORD BUTTON
// The AnimatedContainer (the inner square/circle) is passed as `child` to
// AnimatedBuilder so Flutter builds it exactly once per _rec toggle, not at
// every animation frame (60 fps).  The outer ring containers are lightweight
// and kept inside builder only because their border alpha must track pulseAnim.
// ═══════════════════════════════════════════════════════════════════════════════
class _RecBtn extends StatelessWidget {
  final bool rec;
  final VoidCallback onTap;
  final Animation<double> anim;
  const _RecBtn({required this.rec, required this.onTap, required this.anim});

  // Static ring decoration for the idle outer ring (always full-white border).
  static const _ringIdle = BoxDecoration(
    shape: BoxShape.circle,
    border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 2.5)),
  );
  // Static ring decoration for the recording outer ring.
  static const _ringRec = BoxDecoration(
    shape: BoxShape.circle,
    border: Border.fromBorderSide(BorderSide(color: _kWhite40, width: 2.5)),
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedBuilder(
      animation: anim,
      // Built once per _rec state change, reused every animation frame.
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
          // Pulsing outer ring — only present during recording.
          // Color.fromARGB is a cheap int operation; no Color.lerp involved.
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
          // Static outer ring — uses a const decoration when not recording.
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
// SHUTTER BUTTON
// Four static const decorations (2 outer × 2 inner) eliminate all allocation
// during the ScaleTransition that drives this widget.
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
// FLIP BUTTON
// The icon is passed as `child` to AnimatedBuilder — it is built once per
// isFront toggle, not 60× per second during the spin animation.
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
              // Icon built once; only Transform.rotate re-evaluates at 60 fps.
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
// CustomPainter with shouldRepaint=false and a static Paint object:
// the GPU path is recorded once and composited directly — zero CPU work per frame.
// ═══════════════════════════════════════════════════════════════════════════════
class _ScannerFrame extends StatelessWidget {
  final double size;
  const _ScannerFrame({required this.size});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size), painter: _ScannerPainter());
}

class _ScannerPainter extends CustomPainter {
  // Static Paint — allocated once for the lifetime of the app.
  static final _p = Paint()
    ..color = Colors.white
    ..strokeWidth = 3.5
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size sz) {
    const r = 10.0;
    final arm = sz.width * 0.18;
    final w = sz.width;
    final h = sz.height;

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
// GALLERY SHEET
// Only materialises when the user opens it.  All fixed decorations are static
// const. The thumbnail strip uses ListView.builder so only the ~3 visible items
// are built at any time regardless of session length.
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

  File? _thumb(int i) => _hasVid
      ? (i == 0
            ? (widget.photos.isNotEmpty ? widget.photos.first : null)
            : widget.photos[i - 1])
      : widget.photos[i];

  File _photoAt(int i) => _hasVid ? widget.photos[i - 1] : widget.photos[i];

  Future<void> _open() =>
      OpenFilex.open(_isVid(_sel) ? widget.videoPath! : _photoAt(_sel).path);

  // ── Static const decorations ──────────────────────────────────────────────
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
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: DecoratedBox(
        decoration: _sheetDeco,
        child: Column(
          children: [
            // Handle
            const SizedBox(height: 12),
            const SizedBox(
              width: 40,
              height: 4,
              child: DecoratedBox(decoration: _handleDeco),
            ),
            const SizedBox(height: 12),

            // Header
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

            // Main preview area
            Expanded(
              child: GestureDetector(
                onTap: _open,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Photo preview
                    if (!_isVid(_sel))
                      Positioned.fill(
                        child: Image.file(_photoAt(_sel), fit: BoxFit.contain),
                      ),

                    // Video preview (blurred first-photo + dark tint)
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
                                  // ColoredBox cheaper than Container for solid tint
                                  const ColoredBox(color: _kBlack45),
                                ],
                              )
                            : const ColoredBox(color: _kBlack54),
                      ),

                    // Play icon overlay
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

                    // Tap-to-open hint
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

            // Thumbnail strip — builder pattern: only visible items allocated.
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
                            thumb != null
                                ? Image.file(
                                    thumb,
                                    fit: BoxFit.cover,
                                    cacheWidth: 112,
                                  )
                                : const ColoredBox(color: Color(0x1AFFFFFF)),
                            // Video badge
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
                            // Dim overlay for unselected items
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

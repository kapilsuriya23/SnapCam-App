import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

late List<CameraDescription> cameras;

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
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: VideoCapturePage(),
    );
  }
}

class VideoCapturePage extends StatefulWidget {
  const VideoCapturePage({super.key});

  @override
  State<VideoCapturePage> createState() => _VideoCapturePageState();
}

class _VideoCapturePageState extends State<VideoCapturePage>
    with TickerProviderStateMixin {
  CameraController? controller;
  int _currentCameraIndex = 0;
  bool _isSwitchingCamera = false;

  final List<FlashMode> _flashModes = [
    FlashMode.off,
    FlashMode.always,
    FlashMode.auto,
  ];
  int _flashModeIndex = 0;
  FlashMode get _currentFlashMode => _flashModes[_flashModeIndex];

  bool isRecording = false;
  bool _isTakingPhoto = false;
  bool _isSavingVideo = false;
  int secondsElapsed = 0;
  int photoCount = 0;

  Timer? recordingTimer;
  File? lastPhotoFile;
  bool _photoFlash = false;

  final List<String> _videoSegments = [];

  static const _mediaStore = MethodChannel('com.example.app/media_store');

  // Animations
  late AnimationController _pulseController;
  late AnimationController _shutterController;
  late AnimationController _photoCountController;
  late AnimationController _flipController;
  late AnimationController _flashController;
  late Animation<double> _pulseAnim;
  late Animation<double> _shutterScaleAnim;
  late Animation<double> _photoCountScaleAnim;
  late Animation<double> _flipAnim;
  late Animation<double> _flashAnim;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    // FIX: pulse only starts when recording, not on app launch
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _shutterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _shutterScaleAnim = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _shutterController, curve: Curves.easeInOut),
    );

    _photoCountController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _photoCountScaleAnim =
        TweenSequence([
          TweenSequenceItem(
            tween: Tween<double>(begin: 1.0, end: 1.5),
            weight: 50,
          ),
          TweenSequenceItem(
            tween: Tween<double>(begin: 1.5, end: 1.0),
            weight: 50,
          ),
        ]).animate(
          CurvedAnimation(
            parent: _photoCountController,
            curve: Curves.elasticOut,
          ),
        );

    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _flipAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );

    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _flashAnim = TweenSequence(
      [
        TweenSequenceItem(
          tween: Tween<double>(begin: 1.0, end: 1.4),
          weight: 50,
        ),
        TweenSequenceItem(
          tween: Tween<double>(begin: 1.4, end: 1.0),
          weight: 50,
        ),
      ],
    ).animate(CurvedAnimation(parent: _flashController, curve: Curves.easeOut));

    initCamera();
  }

  Future<void> initCamera() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.photos,
      Permission.videos,
    ].request();
    await _initCameraAt(_currentCameraIndex);
  }

  Future<void> _initCameraAt(int index) async {
    if (index >= cameras.length) return;
    final oldController = controller;
    controller = null;
    if (mounted) setState(() {});
    await oldController?.dispose();

    final newController = CameraController(
      cameras[index],
      ResolutionPreset.high,
      enableAudio: true,
      // FIX: disable image stream — not needed, saves CPU
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await newController.initialize();
    await newController.setFlashMode(_currentFlashMode);
    controller = newController;
    if (mounted) setState(() {});
  }

  Future<void> toggleCamera() async {
    if (isRecording || _isSwitchingCamera || cameras.length < 2) return;
    setState(() => _isSwitchingCamera = true);
    _flipController.forward(from: 0);
    final nextIndex = (_currentCameraIndex == 0) ? 1 : 0;
    _currentCameraIndex = nextIndex;
    await _initCameraAt(nextIndex);
    if (_isFrontCamera && _currentFlashMode != FlashMode.off) {
      _flashModeIndex = 0;
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _isSwitchingCamera = false);
  }

  Future<void> cycleFlashMode() async {
    if (_isFrontCamera) return;
    _flashController.forward(from: 0);
    _flashModeIndex = (_flashModeIndex + 1) % _flashModes.length;
    try {
      await controller?.setFlashMode(_currentFlashMode);
    } catch (e) {
      debugPrint('Flash error: $e');
    }
    if (mounted) setState(() {});
  }

  bool get _isFrontCamera =>
      cameras.isNotEmpty &&
      _currentCameraIndex < cameras.length &&
      cameras[_currentCameraIndex].lensDirection == CameraLensDirection.front;

  IconData get _flashIcon {
    switch (_currentFlashMode) {
      case FlashMode.off:
        return Icons.flash_off_rounded;
      case FlashMode.always:
        return Icons.flash_on_rounded;
      case FlashMode.auto:
        return Icons.flash_auto_rounded;
      default:
        return Icons.flash_off_rounded;
    }
  }

  String get _flashLabel {
    switch (_currentFlashMode) {
      case FlashMode.off:
        return 'OFF';
      case FlashMode.always:
        return 'ON';
      case FlashMode.auto:
        return 'AUTO';
      default:
        return 'OFF';
    }
  }

  bool get _flashIsActive => _currentFlashMode == FlashMode.always;

  String formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> startRecording() async {
    if (controller == null || controller!.value.isRecordingVideo) return;
    _videoSegments.clear();
    await controller!.startVideoRecording();
    // FIX: start pulse animation only when recording begins
    _pulseController.repeat(reverse: true);
    setState(() {
      isRecording = true;
      secondsElapsed = 0;
      photoCount = 0;
    });
    recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // FIX: only update the timer value, not the whole page
      if (mounted) setState(() => secondsElapsed++);
    });
  }

  Future<void> stopRecording() async {
    if (controller == null || !controller!.value.isRecordingVideo) return;
    recordingTimer?.cancel();
    // FIX: stop pulse animation when recording ends
    _pulseController.stop();
    _pulseController.reset();
    final videoFile = await controller!.stopVideoRecording();
    _videoSegments.add(videoFile.path);
    setState(() {
      isRecording = false;
      secondsElapsed = 0;
      photoCount = 0;
      _isSavingVideo = true;
    });
    try {
      final stitchedPath = await _stitchSegments(_videoSegments);
      await _mediaStore.invokeMethod('saveVideoToGallery', {
        'path': stitchedPath,
      });
    } catch (e) {
      debugPrint('Failed to save video: $e');
    } finally {
      if (mounted) setState(() => _isSavingVideo = false);
      _videoSegments.clear();
    }
  }

  Future<String> _stitchSegments(List<String> segments) async {
    if (segments.length == 1) return segments.first;
    final dir = await getTemporaryDirectory();
    final outputPath = p.join(
      dir.path,
      'stitched_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );
    await _mediaStore.invokeMethod('stitchVideos', {
      'segments': segments,
      'output': outputPath,
    });
    return outputPath;
  }

  Future<void> capturePhotoDuringRecording() async {
    if (controller == null ||
        !controller!.value.isRecordingVideo ||
        controller!.value.isTakingPicture ||
        _isTakingPhoto) {
      return;
    }
    setState(() => _isTakingPhoto = true);
    _shutterController.forward().then((_) => _shutterController.reverse());

    try {
      final segmentFile = await controller!.stopVideoRecording();
      _videoSegments.add(segmentFile.path);
      final image = await controller!.takePicture();

      setState(() => _photoFlash = true);
      await Future.delayed(const Duration(milliseconds: 80));
      if (mounted) setState(() => _photoFlash = false);

      await _savePhotoToGallery(image.path);
      _photoCountController.forward(from: 0);
      await controller!.startVideoRecording();
    } catch (e) {
      debugPrint('Error during photo capture: $e');
    } finally {
      if (mounted) setState(() => _isTakingPhoto = false);
    }
  }

  Future<void> _savePhotoToGallery(String sourcePath) async {
    try {
      final snapcam = Directory('/storage/emulated/0/DCIM/SnapCam');
      if (!await snapcam.exists()) await snapcam.create(recursive: true);
      final ext = p.extension(sourcePath).isNotEmpty
          ? p.extension(sourcePath)
          : '.jpg';
      final destPath = p.join(
        snapcam.path,
        'IMG_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await File(sourcePath).copy(destPath);
      await _mediaStore.invokeMethod('scanFile', {'path': destPath});
      if (mounted) {
        setState(() {
          lastPhotoFile = File(destPath);
          photoCount++;
        });
      }
    } catch (e) {
      debugPrint('Error saving photo: $e');
    }
  }

  Future<void> openLastPhoto() async {
    if (lastPhotoFile == null) return;
    await OpenFilex.open(lastPhotoFile!.path);
  }

  @override
  void dispose() {
    recordingTimer?.cancel();
    controller?.dispose();
    _pulseController.dispose();
    _shutterController.dispose();
    _photoCountController.dispose();
    _flipController.dispose();
    _flashController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (controller == null || !controller!.value.isInitialized) {
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

    final size = MediaQuery.of(context).size;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Camera preview — fills entire screen ─────────────────
            RepaintBoundary(
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller!.value.previewSize!.height,
                    height: controller!.value.previewSize!.width,
                    child: CameraPreview(controller!),
                  ),
                ),
              ),
            ),

            // ── Gradient overlays ────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: size.height * 0.22,
              child: const DecoratedBox(
                // FIX: const DecoratedBox — never rebuilds
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
              height: size.height * 0.35,
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

            // ── Photo flash ──────────────────────────────────────────
            if (_photoFlash)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
              ),

            // ── Scanner frame ────────────────────────────────────────
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(child: _ScannerFrame(size: 220)),
              ),
            ),

            // ── Saving overlay ───────────────────────────────────────
            if (_isSavingVideo)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.72),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            color: Colors.white.withValues(alpha: 0.9),
                            strokeWidth: 1.5,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
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

            // ── Top bar ──────────────────────────────────────────────
            Positioned(
              top: topPad + 16,
              left: 24,
              right: 24,
              child: RepaintBoundary(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: isRecording
                          ? _RecordingBadge(
                              key: const ValueKey('rec'),
                              pulseAnim: _pulseAnim,
                              time: formatTime(secondsElapsed),
                            )
                          : const SizedBox(key: ValueKey('idle'), width: 80),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: !isRecording
                          ? _FlashButton(
                              key: const ValueKey('flash'),
                              icon: _flashIcon,
                              label: _flashLabel,
                              isActive: _flashIsActive,
                              isDisabled: _isFrontCamera,
                              scaleAnim: _flashAnim,
                              onTap: cycleFlashMode,
                            )
                          : const SizedBox(
                              key: ValueKey('no-flash'),
                              width: 60,
                            ),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: isRecording
                          ? ScaleTransition(
                              key: const ValueKey('count'),
                              scale: _photoCountScaleAnim,
                              child: _PhotoCountBadge(count: photoCount),
                            )
                          : const SizedBox(
                              key: ValueKey('no-count'),
                              width: 60,
                            ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Bottom controls ──────────────────────────────────────
            Positioned(
              bottom: 36,
              left: 0,
              right: 0,
              // FIX: RepaintBoundary — button animations don't trigger
              //      camera preview or top bar redraws
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _GalleryThumb(file: lastPhotoFile, onTap: openLastPhoto),
                      _RecordButton(
                        isRecording: isRecording,
                        onTap: isRecording ? stopRecording : startRecording,
                        pulseAnim: _pulseAnim,
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: isRecording
                            ? ScaleTransition(
                                key: const ValueKey('shutter'),
                                scale: _shutterScaleAnim,
                                child: _ShutterButton(
                                  enabled: !_isTakingPhoto,
                                  onTap: capturePhotoDuringRecording,
                                ),
                              )
                            : _FlipButton(
                                key: const ValueKey('flip'),
                                flipAnim: _flipAnim,
                                isFront: _isFrontCamera,
                                enabled:
                                    !_isSwitchingCamera && cameras.length >= 2,
                                onTap: toggleCamera,
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

// ── Flash button ──────────────────────────────────────────────────────────────
class _FlashButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isDisabled;
  final Animation<double> scaleAnim;
  final VoidCallback onTap;

  const _FlashButton({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.isDisabled,
    required this.scaleAnim,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? const Color(0xFFFFD60A) : Colors.white;
    return GestureDetector(
      onTap: isDisabled ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: isDisabled ? 0.25 : 1.0,
        child: ScaleTransition(
          scale: scaleAnim,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFFFFD60A).withValues(alpha: 0.15)
                  : Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: isActive
                    ? const Color(0xFFFFD60A).withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.2),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
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
    );
  }
}

// ── Recording badge ───────────────────────────────────────────────────────────
class _RecordingBadge extends StatelessWidget {
  final Animation<double> pulseAnim;
  final String time;
  const _RecordingBadge({
    super.key,
    required this.pulseAnim,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // FIX: AnimatedBuilder scope is tight — only the dot repaints
          AnimatedBuilder(
            animation: pulseAnim,
            builder: (context, _) => Transform.scale(
              scale: pulseAnim.value,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF3B30),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF3B30).withValues(alpha: 0.6),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // FIX: time text is outside AnimatedBuilder — only rebuilds on
          //      setState from the 1-second timer, not on every animation frame
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
    );
  }
}

// ── Photo count badge ─────────────────────────────────────────────────────────
class _PhotoCountBadge extends StatelessWidget {
  final int count;
  const _PhotoCountBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final bgColor = count > 0
        ? const Color(0xFFFF3B30)
        : Colors.black.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(30),
        boxShadow: count > 0
            ? [
                BoxShadow(
                  color: const Color(0xFFFF3B30).withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
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
    );
  }
}

// ── Gallery thumbnail ─────────────────────────────────────────────────────────
class _GalleryThumb extends StatelessWidget {
  final File? file;
  final VoidCallback onTap;
  const _GalleryThumb({required this.file, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3),
            width: 1,
          ),
          color: Colors.white.withValues(alpha: 0.08),
        ),
        child: file != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.file(
                  file!,
                  fit: BoxFit.cover,
                  // FIX: cache width — avoids full-res decode on every rebuild
                  cacheWidth: 108,
                ),
              )
            : Icon(
                Icons.photo_outlined,
                color: Colors.white.withValues(alpha: 0.4),
                size: 22,
              ),
      ),
    );
  }
}

// ── Main record button ────────────────────────────────────────────────────────
class _RecordButton extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onTap;
  final Animation<double> pulseAnim;

  const _RecordButton({
    required this.isRecording,
    required this.onTap,
    required this.pulseAnim,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // FIX: AnimatedBuilder scope is only the button — not the parent Stack
      child: AnimatedBuilder(
        animation: pulseAnim,
        builder: (context, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              if (isRecording)
                Transform.scale(
                  scale: pulseAnim.value * 1.15,
                  child: Container(
                    width: 86,
                    height: 86,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(
                          0xFFFF3B30,
                        ).withValues(alpha: 0.25 * pulseAnim.value),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: isRecording ? 0.6 : 1.0,
                    ),
                    width: 2.5,
                  ),
                ),
              ),
              // FIX: child passed to AnimatedBuilder so the static inner
              //      container isn't rebuilt on every animation frame
              child!,
            ],
          );
        },
        // FIX: this child is built once and reused across animation frames
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          width: isRecording ? 26 : 58,
          height: isRecording ? 26 : 58,
          decoration: BoxDecoration(
            color: isRecording ? const Color(0xFFFF3B30) : Colors.white,
            borderRadius: BorderRadius.circular(isRecording ? 6 : 29),
          ),
        ),
      ),
    );
  }
}

// ── Shutter button ────────────────────────────────────────────────────────────
class _ShutterButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _ShutterButton({super.key, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: enabled ? 1.0 : 0.25,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.12),
            border: Border.all(
              color: Colors.white.withValues(alpha: enabled ? 0.6 : 0.2),
              width: 1,
            ),
          ),
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: enabled ? 0.9 : 0.3),
              ),
              child: Icon(
                Icons.camera_alt_outlined,
                size: 16,
                color: Colors.black.withValues(alpha: enabled ? 0.85 : 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Flip camera button ────────────────────────────────────────────────────────
class _FlipButton extends StatelessWidget {
  final Animation<double> flipAnim;
  final bool isFront;
  final bool enabled;
  final VoidCallback onTap;

  const _FlipButton({
    super.key,
    required this.flipAnim,
    required this.isFront,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1.0 : 0.3,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          child: Center(
            child: AnimatedBuilder(
              animation: flipAnim,
              // FIX: icon passed as child so it isn't rebuilt every frame
              child: Icon(
                isFront
                    ? Icons.camera_front_outlined
                    : Icons.camera_rear_outlined,
                size: 22,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              builder: (context, child) => Transform.rotate(
                angle: flipAnim.value * 2 * math.pi,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Scanner frame ─────────────────────────────────────────────────────────────
class _ScannerFrame extends StatelessWidget {
  final double size;
  const _ScannerFrame({required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _ScannerFramePainter());
  }
}

class _ScannerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Corner arm length — how long each L-shaped corner line is
    final arm = size.width * 0.18;
    // Corner radius — slight rounding on the outer corner
    final r = 10.0;

    final w = size.width;
    final h = size.height;

    // ── Top-left corner ───────────────────────────────────────────
    // Horizontal arm
    canvas.drawLine(Offset(r, 0), Offset(arm, 0), paint);
    // Vertical arm
    canvas.drawLine(Offset(0, r), Offset(0, arm), paint);
    // Rounded corner arc
    canvas.drawArc(
      Rect.fromLTWH(0, 0, r * 2, r * 2),
      math.pi,
      math.pi / 2,
      false,
      paint,
    );

    // ── Top-right corner ──────────────────────────────────────────
    canvas.drawLine(Offset(w - arm, 0), Offset(w - r, 0), paint);
    canvas.drawLine(Offset(w, r), Offset(w, arm), paint);
    canvas.drawArc(
      Rect.fromLTWH(w - r * 2, 0, r * 2, r * 2),
      math.pi * 1.5,
      math.pi / 2,
      false,
      paint,
    );

    // ── Bottom-left corner ────────────────────────────────────────
    canvas.drawLine(Offset(0, h - arm), Offset(0, h - r), paint);
    canvas.drawLine(Offset(r, h), Offset(arm, h), paint);
    canvas.drawArc(
      Rect.fromLTWH(0, h - r * 2, r * 2, r * 2),
      math.pi / 2,
      math.pi / 2,
      false,
      paint,
    );

    // ── Bottom-right corner ───────────────────────────────────────
    canvas.drawLine(Offset(w, h - arm), Offset(w, h - r), paint);
    canvas.drawLine(Offset(w - arm, h), Offset(w - r, h), paint);
    canvas.drawArc(
      Rect.fromLTWH(w - r * 2, h - r * 2, r * 2, r * 2),
      0,
      math.pi / 2,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

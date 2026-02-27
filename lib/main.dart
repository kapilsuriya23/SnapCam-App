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
  int _currentCameraIndex = 0; // 0 = back, 1 = front
  bool _isSwitchingCamera = false;

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
  late Animation<double> _pulseAnim;
  late Animation<double> _shutterScaleAnim;
  late Animation<double> _photoCountScaleAnim;
  late Animation<double> _flipAnim;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

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

    // Flip animation — full 360 spin
    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _flipAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );

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

    // Dispose old controller first
    final oldController = controller;
    controller = null;
    if (mounted) setState(() {});
    await oldController?.dispose();

    final newController = CameraController(
      cameras[index],
      ResolutionPreset.high,
      enableAudio: true,
    );

    await newController.initialize();
    controller = newController;
    if (mounted) setState(() {});
  }

  Future<void> toggleCamera() async {
    // Cannot switch while recording or switching
    if (isRecording || _isSwitchingCamera || cameras.length < 2) return;

    setState(() => _isSwitchingCamera = true);

    // Play flip spin animation
    _flipController.forward(from: 0);

    final nextIndex = (_currentCameraIndex == 0) ? 1 : 0;
    _currentCameraIndex = nextIndex;

    await _initCameraAt(nextIndex);

    if (mounted) setState(() => _isSwitchingCamera = false);
  }

  bool get _isFrontCamera =>
      cameras.isNotEmpty &&
      _currentCameraIndex < cameras.length &&
      cameras[_currentCameraIndex].lensDirection == CameraLensDirection.front;

  String formatTime(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return "$minutes:$secs";
  }

  Future<void> startRecording() async {
    if (controller == null || controller!.value.isRecordingVideo) return;
    _videoSegments.clear();
    await controller!.startVideoRecording();
    setState(() {
      isRecording = true;
      secondsElapsed = 0;
      photoCount = 0;
    });
    recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => secondsElapsed++);
    });
  }

  Future<void> stopRecording() async {
    if (controller == null || !controller!.value.isRecordingVideo) return;
    recordingTimer?.cancel();
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
        _isTakingPhoto)
      return;

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
      final dcim = Directory('/storage/emulated/0/DCIM/Camera');
      if (!await dcim.exists()) await dcim.create(recursive: true);
      final ext = p.extension(sourcePath).isNotEmpty
          ? p.extension(sourcePath)
          : '.jpg';
      final fileName = 'IMG_${DateTime.now().millisecondsSinceEpoch}$ext';
      final destPath = p.join(dcim.path, fileName);
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview ─────────────────────────────────────────
          Positioned.fill(child: CameraPreview(controller!)),

          // ── Gradient overlays ──────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: size.height * 0.22,
            child: Container(
              decoration: const BoxDecoration(
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
            height: size.height * 0.30,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xEE000000), Colors.transparent],
                ),
              ),
            ),
          ),

          // ── Photo flash ────────────────────────────────────────────
          if (_photoFlash)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: Colors.white.withValues(alpha: 0.75)),
              ),
            ),

          // ── Saving overlay ─────────────────────────────────────────
          if (_isSavingVideo)
            Positioned.fill(
              child: Container(
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

          // ── Top bar ────────────────────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 24,
            right: 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Recording badge
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: isRecording
                      ? _RecordingBadge(
                          key: const ValueKey('recording'),
                          pulseAnim: _pulseAnim,
                          time: formatTime(secondsElapsed),
                        )
                      : const SizedBox(key: ValueKey('idle'), width: 80),
                ),

                // Photo count badge
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: isRecording
                      ? ScaleTransition(
                          key: const ValueKey('count'),
                          scale: _photoCountScaleAnim,
                          child: _PhotoCountBadge(count: photoCount),
                        )
                      : const SizedBox(key: ValueKey('no-count'), width: 60),
                ),
              ],
            ),
          ),

          // ── Bottom controls ────────────────────────────────────────
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 36,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Gallery thumbnail
                  _GalleryThumb(file: lastPhotoFile, onTap: openLastPhoto),

                  // Main record button
                  _RecordButton(
                    isRecording: isRecording,
                    onTap: isRecording ? stopRecording : startRecording,
                    pulseAnim: _pulseAnim,
                  ),

                  // Right side: shutter (recording) or flip (idle)
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
                            enabled: !_isSwitchingCamera && cameras.length >= 2,
                            onTap: toggleCamera,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
          AnimatedBuilder(
            animation: pulseAnim,
            builder: (_, __) => Transform.scale(
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
  const _PhotoCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: count > 0
            ? Colors.white.withValues(alpha: 0.15)
            : Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: count > 0
              ? Colors.white.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.1),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_camera_outlined,
            size: 12,
            color: Colors.white.withValues(alpha: count > 0 ? 0.9 : 0.4),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              color: Colors.white.withValues(alpha: count > 0 ? 0.9 : 0.4),
              fontSize: 13,
              fontWeight: FontWeight.w300,
              letterSpacing: 1,
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
                child: Image.file(file!, fit: BoxFit.cover),
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
      child: AnimatedBuilder(
        animation: pulseAnim,
        builder: (_, __) {
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
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                width: isRecording ? 26 : 58,
                height: isRecording ? 26 : 58,
                decoration: BoxDecoration(
                  color: isRecording ? const Color(0xFFFF3B30) : Colors.white,
                  borderRadius: BorderRadius.circular(isRecording ? 6 : 29),
                ),
              ),
            ],
          );
        },
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
              builder: (_, child) => Transform.rotate(
                // Rotates 360° during the flip animation
                angle: flipAnim.value * 2 * math.pi,
                child: child,
              ),
              child: Icon(
                // Icon changes to reflect which camera is currently active
                isFront
                    ? Icons.camera_front_outlined
                    : Icons.camera_rear_outlined,
                size: 22,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

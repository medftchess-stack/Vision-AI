// VisionTouch AI - main.dart (prototype)
// English UI version with simple settings screen.
// NOTE: This is a reference prototype. Replace fake detectors with real models.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ChangeNotifierProvider(AppState.new, child: const VisionTouchApp()));
}

class AppState extends ChangeNotifier {
  bool running = false;
  bool guidanceMode = false;
  int analysisIntervalSeconds = 2;
  double ttsRate = 0.45;
  bool speakDistance = true;

  void setRunning(bool v) { running = v; notifyListeners(); }
  void setGuidance(bool v) { guidanceMode = v; notifyListeners(); }
  void setInterval(int s) { analysisIntervalSeconds = s; notifyListeners(); }
  void setTtsRate(double r) { ttsRate = r; notifyListeners(); }
  void setSpeakDistance(bool v) { speakDistance = v; notifyListeners(); }
}

class VisionTouchApp extends StatelessWidget {
  const VisionTouchApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionTouch AI',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CameraController? _cameraController;
  bool _cameraReady = false;
  final _analyzer = FrameAnalyzer();
  final _tts = TtsService();
  final _speech = SpeechService();
  final _haptic = HapticService();
  Timer? _periodicTimer;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _analyzer.dispose();
    _tts.dispose();
    _speech.dispose();
    _periodicTimer?.cancel();
    super.dispose();
  }

  Future<void> _initAll() async {
    await _requestPermissions();
    await _initCamera();
    await _tts.init();
    await _speech.init();
    _speech.onCommand = _handleVoiceCommand;
    await _analyzer.loadModels();
    _speech.startListening();
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();
    await Permission.microphone.request();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      _cameraController = CameraController(back, ResolutionPreset.medium, enableAudio: false);
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
    } catch (e) {
      if (kDebugMode) print('Camera init error: $e');
    }
  }

  Future<void> _handleVoiceCommand(String cmd) async {
    final c = cmd.toLowerCase();
    final state = context.read<AppState>();
    if (c.contains('stop') || c.contains('pause') || c.contains('mute')) {
      state.setRunning(false);
      await _tts.speak('Stopped commentary');
      _periodicTimer?.cancel();
      return;
    }
    if (c.contains('start') || c.contains('run')) {
      state.setRunning(true);
      await _tts.speak('Starting analysis');
      _startPeriodic();
      return;
    }
    if (c.contains('what is in front') || c.contains('what is ahead') || c.contains('what is near')) {
      final r = await _captureAndAnalyzeOnce();
      await _speakAnalysis(r);
      return;
    }
    if (c.contains('read') || c.contains('read text') || c.contains('ocr')) {
      final t = await _captureAndReadTextOnce();
      await _tts.speak(t.isEmpty ? 'No readable text found' : t);
      return;
    }
    if (c.contains('is there a person') || c.contains('person')) {
      final has = await _captureAndDetectPersonOnce();
      await _tts.speak(has ? 'Yes, there is a person' : 'No person detected');
      return;
    }
    await _tts.speak('Command not recognized');
  }

  Future<AnalysisResult> _captureAndAnalyzeOnce() async {
    if (!_cameraReady || _cameraController == null) return AnalysisResult.empty();
    final x = await _cameraController!.takePicture();
    return _analyzer.analyzeImagePath(x.path);
  }

  Future<String> _captureAndReadTextOnce() async {
    if (!_cameraReady || _cameraController == null) return '';
    final x = await _cameraController!.takePicture();
    return _analyzer.recognizeTextFromPath(x.path);
  }

  Future<bool> _captureAndDetectPersonOnce() async {
    final r = await _captureAndAnalyzeOnce();
    return r.objects.any((o) => o.label.toLowerCase().contains('person') || o.label.toLowerCase().contains('person'));
  }

  void _startPeriodic() {
    final state = context.read<AppState>();
    state.setRunning(true);
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(Duration(seconds: state.analysisIntervalSeconds), (_) async {
      if (!state.running) return;
      final r = await _captureAndAnalyzeOnce();
      if (r.closestDistanceMeters != null && r.closestDistanceMeters! < 1.0) {
        await _tts.speak('Warning: obstacle ahead');
        _haptic.strongAlert();
      } else if (r.objects.isNotEmpty) {
        final o = r.objects.first;
        final distStr = (o.distanceMeters != null) ? '${o.distanceMeters!.toStringAsFixed(1)} meters' : 'nearby';
        await _tts.speak('${o.label} ${state.speakDistance ? 'at $distStr' : ''}');
        _haptic.mediumAlert();
      } else if (r.text.isNotEmpty) {
        await _tts.speak('Text detected: ${r.text}');
        _haptic.vibrateForText();
      } else {
        // silent (optional)
      }

      if (state.guidanceMode) {
        await _tts.speak('Keep walking, slight right');
      }
    });
  }

  Future<void> _speakAnalysis(AnalysisResult r) async {
    if (r.closestDistanceMeters != null && r.closestDistanceMeters! < 1.0) {
      await _tts.speak('Warning: obstacle ${r.closestDistanceMeters!.toStringAsFixed(1)} meters ahead');
      _haptic.strongAlert();
      return;
    }
    if (r.objects.isNotEmpty) {
      final o = r.objects.first;
      await _tts.speak('${o.label} ${o.distanceMeters != null ? 'about ${o.distanceMeters!.toStringAsFixed(1)} meters' : ''} ${_readableDirection(o)}');
      _haptic.mediumAlert();
      return;
    }
    if (r.text.isNotEmpty) {
      await _tts.speak('Text: ${r.text}');
      _haptic.vibrateForText();
      return;
    }
    await _tts.speak('Nothing notable found');
  }

  String _readableDirection(DetectedObject o) => o.boundingBoxCenterX < 0.4 ? 'to your left' : (o.boundingBoxCenterX > 0.6 ? 'to your right' : 'in front of you');

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('VisionTouch AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: 'Settings',
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cameraReady && _cameraController != null
                ? CameraPreview(_cameraController!)
                : Center(child: Column(mainAxisSize: MainAxisSize.min, children: const [
                    Icon(Icons.camera_alt, size: 64),
                    SizedBox(height: 8),
                    Text('Camera initializing...')
                  ])),
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    if (state.running) {
                      state.setRunning(false);
                      _periodicTimer?.cancel();
                    } else {
                      _startPeriodic();
                    }
                  },
                  icon: Icon(state.running ? Icons.pause : Icons.play_arrow),
                  label: Text(state.running ? 'Stop' : 'Start'),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    final text = await _captureAndReadTextOnce();
                    await _tts.speak(text.isEmpty ? 'No readable text found' : text);
                  },
                  icon: const Icon(Icons.text_fields),
                  label: const Text('Read Text'),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    final r = await _captureAndAnalyzeOnce();
                    await _speakAnalysis(r);
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('What\\'s Ahead?'),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Guidance Mode'),
            subtitle: const Text('Step-by-step navigation prompts'),
            value: state.guidanceMode,
            onChanged: (v) => context.read<AppState>().setGuidance(v),
          ),
          ListTile(
            title: const Text('Analysis Interval'),
            subtitle: Text('${state.analysisIntervalSeconds} seconds'),
            trailing: DropdownButton<int>(
              value: state.analysisIntervalSeconds,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1s')),
                DropdownMenuItem(value: 2, child: Text('2s')),
                DropdownMenuItem(value: 3, child: Text('3s')),
                DropdownMenuItem(value: 5, child: Text('5s')),
              ],
              onChanged: (v) { if (v!=null) context.read<AppState>().setInterval(v); },
            ),
          ),
          ListTile(
            title: const Text('TTS Speed'),
            subtitle: Text('${state.ttsRate.toStringAsFixed(2)}'),
            trailing: Slider(
              min: 0.25,
              max: 1.0,
              value: state.ttsRate,
              onChanged: (v) => context.read<AppState>().setTtsRate(v),
              onChangeEnd: (v) => context.read<AppState>().setTtsRate(v),
            ),
          ),
          SwitchListTile(
            title: const Text('Announce distances'),
            subtitle: const Text('Say approximate distance with objects'),
            value: state.speakDistance,
            onChanged: (v) => context.read<AppState>().setSpeakDistance(v),
          ),
        ],
      ),
    );
  }
}

// ----------------- Analyzer & services (placeholders) -----------------

class FrameAnalyzer {
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<void> loadModels() async {
    // load TFLite or ML models here in real app
  }

  void dispose() {
    _textRecognizer.close();
  }

  Future<AnalysisResult> analyzeImagePath(String path) async {
    final text = await recognizeTextFromPath(path);
    final objects = await _fakeObjectDetection(path);
    double? closest;
    if (objects.isNotEmpty) {
      closest = objects.map((o) => o.estimatedDistanceMeters ?? double.infinity).reduce(min);
    }
    return AnalysisResult(objects: objects, text: text, closestDistanceMeters: closest);
  }

  Future<String> recognizeTextFromPath(String path) async {
    final input = InputImage.fromFilePath(path);
    final result = await _textRecognizer.processImage(input);
    return result.text;
  }

  Future<List<DetectedObject>> _fakeObjectDetection(String path) async {
    try {
      final file = File(path);
      final len = await file.length();
      if (len % 2 == 0) {
        return [DetectedObject(label: 'chair', boundingBoxCenterX: 0.3, distanceMeters: 1.2, estimatedDistanceMeters: 1.2)];
      }
    } catch (_) {}
    return [];
  }
}

class AnalysisResult {
  final List<DetectedObject> objects;
  final String text;
  final double? closestDistanceMeters;
  AnalysisResult({required this.objects, required this.text, this.closestDistanceMeters});
  factory AnalysisResult.empty() => AnalysisResult(objects: [], text: '', closestDistanceMeters: null);
}

class DetectedObject {
  final String label;
  final double boundingBoxCenterX;
  final double? distanceMeters;
  final double? estimatedDistanceMeters;
  DetectedObject({required this.label, required this.boundingBoxCenterX, this.distanceMeters, this.estimatedDistanceMeters});
}

class TtsService {
  final FlutterTts _tts = FlutterTts();

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> speak(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      if (kDebugMode) print('TTS error: $e');
    }
  }

  void dispose() => _tts.stop();
}

class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  Function(String cmd)? onCommand;

  Future<void> init() async {
    final available = await _speech.initialize(onError: (e) {}, onStatus: (s) {});
    if (!available) {
      if (kDebugMode) print('Speech not available');
    }
  }

  void startListening() {
    _speech.listen(onResult: (result) {
      final text = result.recognizedWords;
      if (text.isNotEmpty && onCommand != null && result.finalResult) {
        onCommand!(text);
      }
    }, localeId: 'en_US');
  }

  void stop() => _speech.stop();
  void dispose() => _speech.stop();
}

class HapticService {
  Future<void> mediumAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 120);
    } else {
      HapticFeedback.mediumImpact();
    }
  }

  Future<void> strongAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 300, 100, 300]);
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> vibrateForText() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 50, 120, 50]);
    }
  }
}

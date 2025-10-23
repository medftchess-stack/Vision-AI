VisionTouch AI - Flutter Prototype
==================================

This ZIP contains a Flutter project ready to be built with Codemagic or locally.

Important notes:
- This is a prototype. You must add real TFLite models into `assets/models/` for real object detection.
- Codemagic workflow included (codemagic.yaml) calls `flutter create .` if native folders are missing, allowing build on Codemagic without pre-existing android/ios folders.

How to build on Codemagic (phone-only):
1. Upload this repository to GitHub.
2. Go to https://codemagic.io/start and connect your GitHub repository.
3. Choose the workflow `build-apk` and start the build.
4. Download the generated APK from Codemagic artifacts.

If you plan to build locally (requires Flutter SDK and Android SDK):
```
flutter pub get
flutter build apk --release
```


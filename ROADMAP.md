# FruityVens Roadmap

This roadmap tracks needed fixes, required functions, and future improvements
for FruityVens.

## Must Fix / Verify

- Check Firebase Database rules are secure.
- Make sure API keys are not inside app source.
- Confirm Google sign-in works on a real Android device.
- Confirm Firebase sync works for sign up, login, logout, and guest mode.
- Test offline mode and sync after reconnecting.
- Check Android release signing setup privately.
- Replace any fixed local IP like `192.168.1.9` before final release.
- Change the ESP32-CAM password if using real WPA/WPA2 because `1234` is weak
  and too short for normal WPA.

## Needed Functions

- Inventory add, edit, delete, and price update flow.
- Transaction history filtering and search.
- Sales report export to PDF.
- Cloud sync conflict handling.
- Account recovery and reset password.
- Device linking and unlinking.
- ESP32-CAM connection test screen.
- AI model scan confidence display.
- Low-stock or restock alerts.
- Backup and restore local data.

## Nice Additions

- Screenshots in README.
- Demo video or GIF.
- Dark and light theme polish.
- Release APK on GitHub Releases.
- App version and changelog.
- Simple onboarding screen.
- Better error messages for Firebase, camera, and AI failures.

## Contributor / GitHub Tasks

- Add GitHub issue templates.
- Add pull request template.
- Add labels like `bug`, `feature`, `firebase`, `ui`, `android`, `docs`, and
  `security`.
- Use GitHub Projects or Milestones for school or team tracking.

## Before Release

Run these checks before publishing or sharing a build:

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

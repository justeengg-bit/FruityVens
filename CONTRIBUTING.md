# Contributing to FruityVens

Thanks for helping improve FruityVens. Use this checklist before opening a
pull request so the project stays clean, buildable, and safe to share.

## Contributor Checklist

- Create a new branch before editing.
- Use clear branch names, such as `feature/login-sync` or `fix/report-export`.
- Do not commit API keys.
- Do not commit Firebase service account files.
- Do not commit App Check debug tokens.
- Do not commit `android/key.properties`.
- Do not commit `android/local.properties`.
- Do not commit `.jks` or `.keystore` files.
- Do not commit `build/`, `.dart_tool/`, or `run_logs/`.
- Keep Firebase client config only if needed: `firebase_options.dart` and
  `google-services.json`.
- Run `flutter pub get` after pulling changes.
- Run `flutter analyze` before submitting.
- Run `flutter test` before submitting.
- Run `flutter build apk --debug` if Android-related code changed.
- Test the changed screen or feature manually.
- Keep changes focused on one feature or fix.
- Do not rewrite unrelated files.
- Update README or setup docs if behavior or setup changes.
- Add comments only where the code is hard to understand.
- Use clear commit messages.
- Open a pull request instead of pushing directly to `main`.
- In the pull request, describe what changed.
- In the pull request, mention how it was tested.
- Add screenshots if UI changed.
- Ask before changing Firebase rules, authentication, database schema, or model
  files.
- Wait for review before merging.

## Pull Request Summary

When opening a pull request, include:

- What changed
- Why it changed
- How it was tested
- Screenshots or screen recordings for UI changes

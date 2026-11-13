import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/google_auth.dart';

final googleAuthProvider = Provider<GoogleAuth>((ref) => GoogleAuth.forPlatform());

/// The Google account signed in to BizKhata on this device, or null.
///
/// The app restores it at start-up (see AppController); nothing here talks
/// to Google by itself.
class GoogleUserController extends Notifier<GoogleUser?> {
  @override
  GoogleUser? build() => null;

  /// Signed in before on this device? Done quietly, without a window. Offline
  /// the saved account is kept, so the shop still opens.
  Future<GoogleUser?> restore() async {
    final auth = ref.read(googleAuthProvider);
    final u = auth.user ?? await auth.restore();
    state = u;
    return u;
  }

  Future<GoogleUser> signIn() async => state = await ref.read(googleAuthProvider).signIn();

  Future<void> signOut() async {
    try {
      await ref.read(googleAuthProvider).signOut();
    } finally {
      state = null;
    }
  }
}

final googleUserProvider = NotifierProvider<GoogleUserController, GoogleUser?>(GoogleUserController.new);

/// Whether the signed-in account lets BizKhata use Google Drive. Google's
/// consent page lets people untick Drive and still sign in; the shops then
/// stay on this device until Drive is allowed.
class DriveAccessController extends Notifier<bool> {
  @override
  bool build() => ref.watch(googleUserProvider) != null && ref.watch(googleAuthProvider).driveAllowed;

  /// Ask Google again (the browser on Windows, a dialog on Android).
  Future<void> allow() async {
    try {
      await ref.read(googleAuthProvider).allowDrive();
    } finally {
      recheck();
    }
  }

  /// Read the answer again; called after Drive refused something (`no_drive`).
  void recheck() => state = ref.read(googleUserProvider) != null && ref.read(googleAuthProvider).driveAllowed;
}

final driveAccessProvider = NotifierProvider<DriveAccessController, bool>(DriveAccessController.new);

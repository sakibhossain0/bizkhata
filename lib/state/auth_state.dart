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

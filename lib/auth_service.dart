import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Handles Firebase Auth with Google Sign-In ([google_sign_in] 7.x API).
class AuthService {
  AuthService();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  static bool _googleSignInReady = false;

  Stream<User?> get user => _auth.authStateChanges();

  Future<void> _ensureGoogleSignIn() async {
    if (_googleSignInReady) return;
    await GoogleSignIn.instance.initialize();
    _googleSignInReady = true;
  }

  /// Guest sign-in via Firebase **Anonymous** auth.
  ///
  /// Enable **Anonymous** under Firebase Console → Authentication → Sign-in method.
  Future<UserCredential> signInAnonymously() async {
    return _auth.signInAnonymously();
  }

  /// Returns [UserCredential] on success, `null` if the user dismissed the flow.
  ///
  /// If the current user is **anonymous**, links this Google account to the same
  /// Firebase user ([User.uid] unchanged) so Firestore credits and profile stay intact.
  /// Otherwise performs a normal Google sign-in.
  Future<UserCredential?> signInWithGoogle() async {
    await _ensureGoogleSignIn();
    try {
      final GoogleSignInAccount googleUser =
          await GoogleSignIn.instance.authenticate();
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      final String? idToken = googleAuth.idToken;
      if (idToken == null) {
        throw StateError('Google Sign-In did not return an ID token.');
      }
      final OAuthCredential credential = GoogleAuthProvider.credential(
        idToken: idToken,
      );
      final current = _auth.currentUser;
      if (current != null && current.isAnonymous) {
        return current.linkWithCredential(credential);
      }
      return _auth.signInWithCredential(credential);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      if (_googleSignInReady) {
        await GoogleSignIn.instance.signOut();
      }
      await _auth.signOut();
    } catch (e, st) {
      debugPrint('AuthService.signOut error: $e\n$st');
    }
  }
}

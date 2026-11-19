import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// RFC 7636 PKCE parameters and CSRF `state` token for OAuth 2.0 login.
class PkcePair {
  const PkcePair({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
    this.codeChallengeMethod = 'S256',
  });

  final String codeVerifier;
  final String codeChallenge;
  final String state;
  final String codeChallengeMethod;

  /// Generates a fresh PKCE verifier/challenge pair and random OAuth `state`.
  factory PkcePair.generate({Random? random}) {
    final secureRandom = random ?? Random.secure();
    final verifier = _randomBase64Url(secureRandom, byteLength: 64);
    final challenge = computeS256Challenge(verifier);
    final state = _randomBase64Url(secureRandom, byteLength: 32);

    return PkcePair(
      codeVerifier: verifier,
      codeChallenge: challenge,
      state: state,
    );
  }

  /// Computes the RFC 7636 `S256` code challenge (`BASE64URL-ENCODE(SHA256(verifier))`
  /// without `=` padding).
  static String computeS256Challenge(String codeVerifier) {
    final digest = sha256.convert(ascii.encode(codeVerifier));
    return _base64UrlNoPadding(digest.bytes);
  }

  static String _randomBase64Url(Random random, {required int byteLength}) {
    final bytes = List<int>.generate(byteLength, (_) => random.nextInt(256));
    return _base64UrlNoPadding(bytes);
  }

  static String _base64UrlNoPadding(List<int> bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

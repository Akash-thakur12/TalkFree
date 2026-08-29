/// Maps raw API / server strings to short, user-safe copy (no provider names / .env).
String userFacingServiceError(String raw) {
  final s = raw.trim();
  if (s.isEmpty) {
    return 'Something went wrong. Please try again later.';
  }
  final lower = s.toLowerCase();
  if (lower.contains('twilio')) {
    return 'Service is temporarily unavailable. Please try again later.';
  }
  if (lower.contains('trial') ||
      lower.contains('.env') ||
      lower.contains('sms from number')) {
    return 'Service is temporarily busy. Please try again later.';
  }
  return s;
}

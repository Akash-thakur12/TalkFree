/// Pretty-print E.164 US numbers for display (fallback: raw string).
String formatUsPhoneForDisplay(String e164) {
  final buf = StringBuffer();
  for (final c in e164.runes) {
    final ch = String.fromCharCode(c);
    if (RegExp(r'\d').hasMatch(ch)) buf.write(ch);
  }
  final d = buf.toString();
  if (d.length == 11 && d.startsWith('1')) {
    final r = d.substring(1);
    if (r.length == 10) {
      return '+1 ${r.substring(0, 3)} ${r.substring(3, 6)} ${r.substring(6)}';
    }
  }
  if (d.length == 10) {
    return '+1 ${d.substring(0, 3)} ${d.substring(3, 6)} ${d.substring(6)}';
  }
  return e164.trim();
}

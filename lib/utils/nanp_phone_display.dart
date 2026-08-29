/// Formats NANP E.164 (+1…) for display (US/CA).
abstract final class NanpPhoneDisplay {
  NanpPhoneDisplay._();

  static String format(String e164) {
    final digits = e164.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('1')) {
      final a = digits.substring(1, 4);
      final b = digits.substring(4, 7);
      final c = digits.substring(7);
      return '+1 ($a) $b-$c';
    }
    if (digits.length == 10) {
      final a = digits.substring(0, 3);
      final b = digits.substring(3, 6);
      final c = digits.substring(6);
      return '+1 ($a) $b-$c';
    }
    return e164;
  }
}

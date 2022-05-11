import 'dart:math';

import 'package:clock/clock.dart';
import 'package:intl/intl.dart';

final _splitPatternRegexp = RegExp(r'[\p{P}\s]+', unicode: true);
final _quotedToken = RegExp(r"'[^']*'");
final _punctOrSpaceRegexp = RegExp(r'[\p{P}\s]', unicode: true);
final _digitRegexp = RegExp(r'\d');

/// Parse a date or datetime string, based on [parseFormats], and return a
/// DateTime. Each [parseFormat] is attempted in order until [inputString] is successfully
/// parsed. If [allowAmbiguousYear] is true (the default), a two-digit year can be
/// supplied that is exactly 20 years in the future or exactly 80 years in the past -
/// e.g., "22" for "2022".
/// A [FormatException] is thrown if [inputString] cannot be parsed.
DateTime parseDateTime(
  String inputString, {
  bool utc = false,
  required List<DateFormat> parserFormats,
  bool allowAmbiguousYear = true,
}) {
  final inputParts = _splitInput(inputString);
  if (inputParts.isEmpty) {
    throw FormatException('Invalid input: $inputString');
  }

  for (final parserFormat in parserFormats) {
    try {
      return _tryParse(inputParts,
          utc: utc,
          parserFormat: parserFormat,
          allowAmbiguousYear: allowAmbiguousYear);
    } catch (e) {
      if (identical(parserFormat, parserFormats.last)) {
        rethrow;
      }
    }
  }

  throw const FormatException('Could not parse');
}

/// Splits the input into digit sequences or non-punctuation sequences. A single
/// part returned will not be a combination of digits and non-punctuation.
/// We need this instead of split() in order to break "12:00pm" into "12" "00" "pm".
List<String> _splitInput(String input) {
  final parts = <String>[];
  final builder = StringBuffer();
  void emit() {
    if (builder.isNotEmpty) {
      parts.add(builder.toString());
      builder.clear();
    }
  }

  bool lastCharWasDigit = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (_punctOrSpaceRegexp.hasMatch(c)) {
      emit();
    } else if (_digitRegexp.hasMatch(c)) {
      if (!lastCharWasDigit) {
        emit();
      }

      builder.write(c);
      lastCharWasDigit = true;
    } else {
      if (lastCharWasDigit) {
        emit();
      }

      builder.write(c);
      lastCharWasDigit = false;
    }
  }

  emit();
  return parts;
}

DateTime _tryParse(
  List<String> inputParts, {
  bool utc = false,
  required DateFormat parserFormat,
  bool allowAmbiguousYear = true,
}) {
  var pattern = parserFormat.pattern ?? 'M/d/y';
  // Get rid of quoted text like 'T'
  pattern = pattern.replaceAll(_quotedToken, ' ');

  final patternParts = pattern.split(_splitPatternRegexp);
  final builder = _Builder();
  var inputIdx = 0;
  for (final patternPart in patternParts) {
    final symbol = patternPart[0];
    final handler = _symbolHandlers[symbol];
    if (handler != null) {
      final input = inputIdx < inputParts.length
          ? inputParts[inputIdx]
          : handler.defaultValue;
      ++inputIdx;

      handler.setValue(builder, input);
    }
  }

  // If we still have input left, consider it an error - at least not matching this format.
  if (inputIdx < inputParts.length) {
    throw FormatException('Unexpected input ${inputParts[inputIdx]}');
  }

  // Default am/pm to am if this is a 12h format.
  if (!builder.patternIs24hr && builder.am == null) {
    builder.am = true;
  }

  // Fix-up hour if am/pm was specified.
  if (builder.hour != null && builder.am != null) {
    // Hour should be 0..11 if this is really a 12h hour. During conversion of 'h',
    // we subtracted 1 from the hour. However, keep in mind that the user could have
    // supplied a 24h hour without an am/pm indicator, so if the hour > 12, we want to preserve
    // the hour as-is.
    if (!builder.am! && builder.hour! < 12) {
      builder.hour = builder.hour! + 12;
    }
  }

  var now = clock.now();
  if (utc) {
    now = now.toUtc();
  }

  // Fix up two-digit years if allowAmbiguousYear is true
  if (builder.year != null &&
      allowAmbiguousYear &&
      builder.year! >= 10 &&
      builder.year! <= 99) {
    // Basic algorithm from package:intl/lib/src/intl/date_builder.dart.
    const lookBehindYears = 80;
    final lowerYear = now.year - lookBehindYears;
    final upperYear = now.year + (100 - lookBehindYears);
    final lowerCentury = (lowerYear ~/ 100) * 100;
    final upperCentury = (upperYear ~/ 100) * 100;
    var candidateYear = upperCentury + builder.year!;

    // Our interval must be half-open since there otherwise could be ambiguity
    // for a date that is exactly 20 years in the future or exactly 80 years
    // in the past (mod 100).  We'll treat the lower-bound date as the
    // exclusive bound because:
    // * It's farther away from the present, and we're less likely to care
    //   about it.
    // * By the time this function exits, time will have advanced to favor
    //   the upper-bound date.
    //
    // We don't actually need to check both bounds.
    if (candidateYear <= upperYear) {
      // Within range.
      assert(candidateYear > lowerYear);
    } else {
      candidateYear = lowerCentury + builder.year!;
    }

    builder.year = candidateYear;
  }

  // Default the year to this year.
  if (builder.year == null || builder.year == 0) {
    builder.year = now.year;
  }

  final result = DateTime(
      builder.year ?? now.year,
      builder.month ?? now.month,
      builder.day ?? now.day,
      builder.hour ?? 0,
      builder.minute ?? 0,
      builder.second ?? 0,
      builder.millisecond ?? 0);
  return utc ? result.toUtc() : result;
}

class _Builder {
  int? year;

  /// 1..12
  int? month;

  /// 1..31
  int? day;

  /// 0..23
  int? hour;
  int? minute;
  int? second;
  int? millisecond;
  bool? am;

  bool patternIs24hr = false;
}

class _SymbolHandler {
  void Function(_SymbolHandler, _Builder, String) setter;
  String defaultValue;
  late List<DateFormat> symbolFormats;
  final String symbol;

  _SymbolHandler(this.symbol, this.setter, this.defaultValue) {
    symbolFormats = [
      DateFormat(symbol), // e.g., M = 12
      DateFormat('$symbol$symbol$symbol'), // e.g., MMM = Jan
      DateFormat('$symbol$symbol$symbol$symbol'), // e.g., MMMM = January
      DateFormat('$symbol$symbol$symbol$symbol$symbol'), // e.g., MMMMM = J
    ];
  }

  DateTime tryParse(String value) {
    assert(symbolFormats.isNotEmpty);
    for (final symbolFormat in symbolFormats) {
      try {
        return symbolFormat.parseLoose(value);
      } catch (e) {
        if (identical(symbolFormat, symbolFormats.last)) {
          rethrow;
        }
      }
    }

    // We should never get here unless symbolFormats is empty, which is filled with 4 in the constructor.
    throw Exception('Could not parse $value as $symbol');
  }

  void setValue(_Builder builder, String input) => setter(this, builder, input);
}

final _symbolHandlers = <String, _SymbolHandler>{
  ///     y        year                   (Number)           1996
  'y': _SymbolHandler(
      'y',
      (handler, builder, value) => builder.year = handler.tryParse(value).year,
      '0'),

  ///     M        month in year          (Text & Number)    July & 07
  'M': _SymbolHandler(
      'M',
      (handler, builder, value) =>
          builder.month = handler.tryParse(value).month,
      '1'),

  ///     L        standalone month       (Text & Number)    July & 07
  'L': _SymbolHandler(
      'L',
      (handler, builder, value) =>
          builder.month = handler.tryParse(value).month,
      '1'),

  ///     d        day in month           (Number)           10
  'd': _SymbolHandler(
      'd',
      (handler, builder, value) => builder.day = handler.tryParse(value).day,
      '1'),

  ///     h        hour in am/pm (1~12)   (Number)           12
  'h': _SymbolHandler(
      'h',
      (handler, builder, value) => builder.hour = handler.tryParse(value).hour,
      // "12" is parsed as zero by 'h' DateFormat
      '12'),

  ///     H        hour in day (0~23)     (Number)           0
  'H': _SymbolHandler('H', (handler, builder, value) {
    builder.hour = handler.tryParse(value).hour;
    builder.patternIs24hr = true;
  }, '0'),

  ///     k        hour in day (1~24)     (Number)           24
  'k': _SymbolHandler('k', (handler, builder, value) {
    builder.hour = handler.tryParse(value).hour;
    builder.patternIs24hr = true;
  }, '1'),

  ///     K        hour in am/pm (0~11)   (Number)           0
  'K': _SymbolHandler(
      'K',
      (handler, builder, value) => builder.hour = handler.tryParse(value).hour,
      '0'),

  ///     m        minute in hour         (Number)           30
  'm': _SymbolHandler(
      'm',
      (handler, builder, value) =>
          builder.minute = handler.tryParse(value).minute,
      '0'),

  ///     s        second in minute       (Number)           55
  's': _SymbolHandler(
      's',
      (handler, builder, value) =>
          builder.second = handler.tryParse(value).second,
      '0'),

  ///     S        fractional second      (Number)           978
  'S': _SymbolHandler(
      'S',
      (handler, builder, value) =>
          builder.millisecond = handler.tryParse(value).millisecond,
      '0'),

  ///     a        am/pm marker           (Text)             PM
  'a': _SymbolHandler('a', (handler, builder, value) {
    if (value == 'notset') return;

    value = value.toUpperCase();
    final idx = handler.symbolFormats[0].dateSymbols.AMPMS.indexWhere(
        (symbol) =>
            symbol
                .substring(0, min(symbol.length, value.length))
                .toUpperCase() ==
            value);
    if (idx < 0) {
      throw Exception('Invalid AM/PM indicator: $value');
    }

    builder.am = idx == 0;
  }, 'notset'),
};

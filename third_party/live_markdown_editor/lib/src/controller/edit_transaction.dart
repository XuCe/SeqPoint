import 'package:flutter/services.dart';

final class EditTransaction {
  const EditTransaction({required this.before, required this.after});

  final TextEditingValue before;
  final TextEditingValue after;
}

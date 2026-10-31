import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(responseDataCallback: (data) async {
  if (data?['stickyLifecycle'] != true || data?['opened'] != 3 || data?['closed'] != 3) {
    throw StateError('Sticky lifecycle checks did not complete');
  }
});

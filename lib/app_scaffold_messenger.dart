import 'package:flutter/material.dart';

/// Root [ScaffoldMessenger] so services (e.g. [BillingService]) can show
/// lightweight feedback without a [BuildContext].
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:app_links/app_links.dart';
import 'package:provider/provider.dart';
import 'screens/main_navigation_screen.dart';
import 'screens/tutorial_screen.dart';
import 'theme/app_theme.dart';
import 'theme/theme_provider.dart';
import 'services/session_manager.dart';
import 'services/user_service.dart';
import 'services/ad_service.dart';
import 'dart:async';

// Global variable to store initial deep link
String? _initialRemoteId;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // CRITICAL: Run Firebase init and SessionManager in parallel
  // These are the two blocking operations
  await Future.wait([
    Firebase.initializeApp(),
    SessionManager().initialize(),
  ]);
  
  // Start app IMMEDIATELY - don't wait for ads or auth
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );
  
  // Do remaining initialization in background (non-blocking)
  _initializeInBackground();
}

/// Background initialization - doesn't block app startup
Future<void> _initializeInBackground() async {
  // Run all these in parallel - none should block the UI
  unawaited(Future.wait([
    // Initialize Ad Service (lazy - don't block)
    AdService().initialize(),
    
    // Sign in anonymously (lazy - don't block)
    _signInAnonymously(),
    
    // Check for initial deep link
    _checkInitialDeepLink(),
  ]));
  
  // Set user online after a small delay to ensure Firebase is ready
  Future.delayed(const Duration(milliseconds: 500), () {
    UserService().setUserOnline(SessionManager().userId, true);
  });
}

Future<void> _signInAnonymously() async {
  try {
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    // Ignore auth errors
  }
}

Future<void> _checkInitialDeepLink() async {
  try {
    final appLinks = AppLinks();
    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) {
      _initialRemoteId = _extractUserIdFromUri(initialUri);
    }
  } catch (e) {
    // Ignore deep link errors
  }
}

/// Extract user ID from deep link URI
/// Supports formats:
/// - securechat://call/XXXXXXXX
/// - https://securechat.app/call/XXXXXXXX
String? _extractUserIdFromUri(Uri uri) {
  // Check path segments (direct deep link)
  if (uri.pathSegments.isNotEmpty) {
    final lastSegment = uri.pathSegments.last;
    if (lastSegment.length == 8) { // User IDs are 8 characters
      return lastSegment.toUpperCase();
    }
  }
  
  return null;
}

class ChangeNotifierProvider<T extends ChangeNotifier> extends StatefulWidget {
  final T Function(BuildContext) create;
  final Widget child;

  const ChangeNotifierProvider({
    super.key,
    required this.create,
    required this.child,
  });

  @override
  State<ChangeNotifierProvider<T>> createState() => _ChangeNotifierProviderState<T>();

  static T of<T extends ChangeNotifier>(BuildContext context) {
    final provider = context.findAncestorStateOfType<_ChangeNotifierProviderState<T>>();
    if (provider == null) {
      throw Exception('No ChangeNotifierProvider found in context');
    }
    return provider.notifier;
  }
}

class _ChangeNotifierProviderState<T extends ChangeNotifier> extends State<ChangeNotifierProvider<T>> {
  late T notifier;

  @override
  void initState() {
    super.initState();
    notifier = widget.create(context);
    notifier.addListener(_update);
  }

  @override
  void dispose() {
    notifier.removeListener(_update);
    notifier.dispose();
    super.dispose();
  }

  void _update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late AppLinks _appLinks;
  StreamSubscription? _linkSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinkListener();
    
    // Setup Firebase disconnect cleanup after a delay
    Future.delayed(const Duration(seconds: 1), () {
      _setupFirebaseDisconnectCleanup();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _clearAllDataOnClose(SessionManager().userId);
    super.dispose();
  }

  void _setupFirebaseDisconnectCleanup() {
    final userId = SessionManager().userId;
    final database = FirebaseDatabase.instance.ref();
    
    database.child('users/$userId').onDisconnect().remove();
    database.child('user_contacts/$userId').onDisconnect().remove();
    database.child('random_pool/$userId').onDisconnect().remove();
    database.child('presence/$userId').onDisconnect().remove();
    database.child('call_requests/$userId').onDisconnect().remove();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    final userId = SessionManager().userId;
    
    if (state == AppLifecycleState.detached) {
      _clearAllDataOnClose(userId);
    } else if (state == AppLifecycleState.paused) {
      UserService().setUserOnline(userId, false);
    } else if (state == AppLifecycleState.resumed) {
      UserService().setUserOnline(userId, true);
      _setupFirebaseDisconnectCleanup();
    }
  }

  Future<void> _clearAllDataOnClose(String userId) async {
    try {
      await UserService().clearAllUserData(userId);
    } catch (e) {
      // Ignore errors during cleanup
    }
  }

  void _initDeepLinkListener() {
    _appLinks = AppLinks();
    
    _linkSubscription = _appLinks.uriLinkStream.listen((Uri uri) {
      final userId = _extractUserIdFromUri(uri);
      if (userId != null) {
        _navigateWithUserId(userId);
      }
    });
  }

  void _navigateWithUserId(String userId) {
    navigatorKey.currentState?.pushReplacement(
      MaterialPageRoute(
        builder: (context) => MainNavigationScreen(initialRemoteId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = ChangeNotifierProvider.of<ThemeProvider>(context);
    final sessionManager = SessionManager();
    
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Secure Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.themeMode,
      builder: (context, widget) {
        ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
          return ErrorScreen(errorDetails: errorDetails);
        };
        return widget ?? const SizedBox.shrink();
      },
      home: sessionManager.hasSeenTutorial 
          ? MainNavigationScreen(initialRemoteId: _initialRemoteId)
          : const TutorialScreen(isFirstTime: true),
    );
  }
}

// Global navigator key for deep link handling
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class ErrorScreen extends StatelessWidget {
  final FlutterErrorDetails errorDetails;

  const ErrorScreen({super.key, required this.errorDetails});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Something went wrong',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Please restart the app',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

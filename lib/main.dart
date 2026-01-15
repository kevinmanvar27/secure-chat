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
  
  await Firebase.initializeApp();
  
  // Initialize session manager (generates new user ID on every restart)
  await SessionManager().initialize();
  
  // Initialize Ad Service
  await AdService().initialize();
  
  // Check for initial deep link (app opened via link)
  try {
    final appLinks = AppLinks();
    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) {
      _initialRemoteId = _extractUserIdFromUri(initialUri);
    }
  } catch (e) {
    // Ignore deep link errors
  }
  
  try {
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    // Ignore auth errors
  }
  
  // Set user online
  UserService().setUserOnline(SessionManager().userId, true);
  
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };
  
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );
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
    _setupFirebaseDisconnectCleanup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    // Clear data when app is disposed
    _clearAllDataOnClose(SessionManager().userId);
    super.dispose();
  }

  /// Setup Firebase onDisconnect to automatically clear data when connection is lost
  void _setupFirebaseDisconnectCleanup() {
    final userId = SessionManager().userId;
    final database = FirebaseDatabase.instance.ref();
    
    // When user disconnects from Firebase, automatically remove their data
    // This handles cases where app is killed without proper cleanup
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
      // App is being closed - clear all user data from Firebase
      _clearAllDataOnClose(userId);
    } else if (state == AppLifecycleState.paused) {
      // App went to background - set offline but DON'T clear all data yet
      // Firebase onDisconnect will handle cleanup if app is killed
      UserService().setUserOnline(userId, false);
    } else if (state == AppLifecycleState.resumed) {
      // App came back - set user online again and re-setup disconnect handlers
      UserService().setUserOnline(userId, true);
      _setupFirebaseDisconnectCleanup();
    }
  }

  Future<void> _clearAllDataOnClose(String userId) async {
    try {
      // Clear all user data from Firebase
      await UserService().clearAllUserData(userId);
    } catch (e) {
      // Ignore errors during cleanup
    }
  }

  void _initDeepLinkListener() {
    _appLinks = AppLinks();
    
    // Listen for incoming deep links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen((Uri uri) {
      final userId = _extractUserIdFromUri(uri);
      if (userId != null) {
        // Navigate to home with the user ID auto-filled
        _navigateWithUserId(userId);
      }
    });
  }

  void _navigateWithUserId(String userId) {
    // Navigate to main screen with the ID auto-filled (no dialog)
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

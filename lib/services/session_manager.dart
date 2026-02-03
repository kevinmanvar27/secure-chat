import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

/// Singleton class to manage user session ID and room ID
/// User ID is generated fresh on every app restart
class SessionManager {
  // Singleton instance
  static final SessionManager _instance = SessionManager._internal();
  
  factory SessionManager() {
    return _instance;
  }
  
  SessionManager._internal();
  
  // User ID - generated fresh on every app restart
  String? _userId;
  
  // Whether user has seen tutorial
  bool _hasSeenTutorial = false;
  
  // Current room ID - persists until explicitly cleared or app closes
  String? _currentRoomId;
  
  // Current request ID for call requests
  String? _currentRequestId;
  
  /// Initialize session manager (call this at app start)
  /// Generates a NEW user ID every time app restarts
  Future<void> initialize() async {
    // Generate user ID IMMEDIATELY - no waiting
    _userId = const Uuid().v4().substring(0, 8).toUpperCase();
    
    // Load SharedPreferences - we need hasSeenTutorial before showing UI
    final prefs = await SharedPreferences.getInstance();
    
    // Load tutorial status (needed for initial screen decision)
    _hasSeenTutorial = prefs.getBool('has_seen_tutorial') ?? false;
    
    // Save the new ID in background - don't await
    unawaited(prefs.setString('user_id', _userId!));
  }
  
  /// Get the current user ID
  String get userId => _userId ?? 'LOADING';
  
  /// Check if user has seen tutorial
  bool get hasSeenTutorial => _hasSeenTutorial;
  
  /// Mark tutorial as seen
  Future<void> markTutorialSeen() async {
    _hasSeenTutorial = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_tutorial', true);
  }
  
  /// Alias for markTutorialSeen - used for first launch completion
  Future<void> setFirstLaunchComplete() async {
    await markTutorialSeen();
  }
  
  /// Get the current room ID
  String? get currentRoomId => _currentRoomId;
  
  /// Set the current room ID
  set currentRoomId(String? roomId) {
    _currentRoomId = roomId;
  }
  
  /// Get the current request ID
  String? get currentRequestId => _currentRequestId;
  
  /// Set the current request ID
  set currentRequestId(String? requestId) {
    _currentRequestId = requestId;
  }
  
  /// Clear room and request IDs (called when leaving a call)
  void clearCallSession() {
    _currentRoomId = null;
    _currentRequestId = null;
  }
}

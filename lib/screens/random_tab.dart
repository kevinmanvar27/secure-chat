import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_service.dart';
import '../services/session_manager.dart';
import '../services/webrtc_service.dart';
import '../services/ad_service.dart';
import '../theme/app_theme.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

// Video layout types for random calls
enum RandomVideoLayoutType { whatsapp, omegle }

class RandomTab extends StatefulWidget {
  const RandomTab({super.key});

  @override
  State<RandomTab> createState() => RandomTabState();
}

class RandomTabState extends State<RandomTab> with WidgetsBindingObserver {
  final SessionManager _sessionManager = SessionManager();
  final UserService _userService = UserService();
  final WebRTCService _webrtcService = WebRTCService();
  final AdService _adService = AdService();
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  
  String get myUserId => _sessionManager.userId;
  
  // Video renderers
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  
  // State
  bool _isTabActive = false;
  bool _isSearching = false;
  bool _isConnected = false;
  bool _isCameraReady = false;
  bool _hasPermissions = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isFrontCamera = true;
  bool _isConnecting = false;
  
  // Session ID to track current connection session - prevents old stream issues
  String? _currentSessionId;
  
  // IMPORTANT: Track skipped/connected users in this session to avoid reconnecting
  final Set<String> _skippedUsersThisSession = {};
  
  // Track if user manually stopped - prevents auto-restart
  bool _manuallyStopped = false;
  
  // Successful connection counter for ads
  int _successfulConnectionCount = 0;
  static const int _adAfterConnections = 3;
  
  // Auto-hide UI when connected
  bool _isUIVisible = true;
  Timer? _uiHideTimer;
  static const Duration _uiHideDelay = Duration(seconds: 4);
  
  // Stream health check timer - refreshes stream every 10 minutes to prevent stale state
  Timer? _streamHealthTimer;
  static const Duration _streamHealthCheckInterval = Duration(minutes: 10);
  
  String _statusText = 'Tap Start to find someone';
  String? _connectedUserId;
  String? _currentRoomId;
  
  Timer? _searchTimer;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _disconnectSubscription;
  StreamSubscription? _matchSubscription;
  StreamSubscription? _localStreamSubscription;
  
  // Banner settings (controlled from admin panel via Firebase)
  bool _showBanner = false;
  Color _bannerColor = const Color(0xFFFF6B00); // Default to primary orange
  StreamSubscription? _bannerSubscription;
  
  // Video layout preference
  RandomVideoLayoutType _videoLayout = RandomVideoLayoutType.whatsapp;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenToBannerSettings();
    _loadVideoLayoutPreference();
  }
  
  Future<void> _loadVideoLayoutPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLayout = prefs.getString('random_video_layout_preference');
    if (savedLayout != null && mounted) {
      setState(() {
        _videoLayout = savedLayout == 'omegle' 
            ? RandomVideoLayoutType.omegle 
            : RandomVideoLayoutType.whatsapp;
      });
    }
  }
  
  Future<void> _saveVideoLayoutPreference(RandomVideoLayoutType layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('random_video_layout_preference', layout == RandomVideoLayoutType.omegle ? 'omegle' : 'whatsapp');
  }
  
  void _toggleVideoLayout() {
    setState(() {
      _videoLayout = _videoLayout == RandomVideoLayoutType.whatsapp
          ? RandomVideoLayoutType.omegle
          : RandomVideoLayoutType.whatsapp;
    });
    _saveVideoLayoutPreference(_videoLayout);
  }
  
  /// Listen to banner settings from Firebase
  void _listenToBannerSettings() {
    _bannerSubscription = _database.child('app_settings/random_banner').onValue.listen((event) {
      if (mounted) {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        setState(() {
          _showBanner = data?['enabled'] as bool? ?? false;
          // Parse color if provided, default to purple
          final colorHex = data?['color'] as String?;
          if (colorHex != null && colorHex.isNotEmpty) {
            try {
              _bannerColor = Color(int.parse(colorHex.replaceFirst('#', '0xFF')));
            } catch (_) {
              _bannerColor = const Color(0xFFFF6B00); // Default to primary orange
            }
          }
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiHideTimer?.cancel();
    _streamHealthTimer?.cancel();
    _bannerSubscription?.cancel();
    _cleanup();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopEverything();
    } else if (state == AppLifecycleState.resumed && _isTabActive) {
      // Force reinitialize on resume to ensure fresh state
      _forceReinitialize();
    }
  }

  bool _renderersInitialized = false;
  
  /// Called when tab becomes active - lazy initialization
  void onTabActive() async {
    if (!_isTabActive) {
      _isTabActive = true;
      
      // Initialize renderers only when tab is first activated
      if (!_renderersInitialized) {
        await _initRenderers();
        _renderersInitialized = true;
      }
      
      // ALWAYS reset and reinitialize when tab becomes active
      // This ensures clean state after coming from private calls
      await _forceReinitialize();
    }
  }
  
  /// Force reinitialize WebRTC and camera for fresh state
  Future<void> _forceReinitialize() async {
    print('🔄 Force reinitializing random tab...');
    
    // Reset camera ready state to force reinitialization
    _isCameraReady = false;
    
    // Cancel stream health timer
    _streamHealthTimer?.cancel();
    
    // Cancel any existing subscriptions
    _remoteStreamSubscription?.cancel();
    _disconnectSubscription?.cancel();
    _localStreamSubscription?.cancel();
    
    // Clear renderers first
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    
    // Reset WebRTC service - this will close peer connection but NOT reinitialize stream
    // We'll do that in _initCamera
    await _webrtcService.resetConnectionWithoutStreamReinit();
    
    // Small delay to ensure cleanup is complete
    await Future.delayed(const Duration(milliseconds: 200));
    
    // Now initialize camera with fresh state (this will create fresh stream)
    await _initCamera();
    
    // Start stream health check timer
    _startStreamHealthCheck();
    
    print('✓ Force reinitialization complete');
  }
  
  /// Periodically check and refresh stream health to prevent stale connections
  void _startStreamHealthCheck() {
    _streamHealthTimer?.cancel();
    _streamHealthTimer = Timer.periodic(_streamHealthCheckInterval, (timer) async {
      if (!_isTabActive || !mounted) {
        timer.cancel();
        return;
      }
      
      // Only refresh if not in a call
      if (!_isConnected && !_isConnecting && !_isSearching) {
        print('🔄 Stream health check - refreshing local stream');
        await _refreshLocalStream();
      }
    });
  }
  
  /// Refresh local stream without full reinitialization
  Future<void> _refreshLocalStream() async {
    if (!_isTabActive || _isConnected || _isConnecting) return;
    
    try {
      // Reinitialize local stream in WebRTC service
      await _webrtcService.initializeLocalStream();
      
      // Update renderer
      if (mounted && _webrtcService.currentLocalStream != null) {
        _localRenderer.srcObject = _webrtcService.currentLocalStream;
        setState(() {
          _isCameraReady = true;
        });
      }
    } catch (e) {
      print('Error refreshing local stream: $e');
    }
  }

  /// Called when tab becomes inactive
  Future<bool> onTabInactive() async {
    if (_isConnected || _isConnecting) {
      // Show confirmation dialog
      final shouldLeave = await _showLeaveConfirmation();
      if (!shouldLeave) {
        return false; // Don't allow tab switch
      }
    }
    
    _isTabActive = false;
    _stopEverything();
    return true;
  }

  Future<bool> _showLeaveConfirmation() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.getSurfaceColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.getPrimaryColor(context), size: 28),
            const SizedBox(width: 12),
            Text('End Call?', style: TextStyle(color: AppTheme.getOnSurfaceColor(context))),
          ],
        ),
        content: Text(
          'You are currently in a call. Switching tabs will end the call. Are you sure?',
          style: TextStyle(color: AppTheme.getOnSurfaceColor(context).withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Stay', style: TextStyle(color: AppTheme.getSecondaryColor(context))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('End Call', style: TextStyle(color: AppTheme.getErrorColor(context))),
          ),
        ],
      ),
    );
    
    return result ?? false;
  }

  void _stopEverything() {
    _currentSessionId = null;
    WakelockPlus.disable();
    
    _streamHealthTimer?.cancel();
    _endCurrentCall();
    _stopSearching();
    _disposeLocalStream();
    
    if (mounted) {
      setState(() {
        _isCameraReady = false;
        _isConnected = false;
        _isConnecting = false;
        _connectedUserId = null;
        _statusText = 'Tap Start to find someone';
      });
    }
  }

  void _cleanup() {
    _currentSessionId = null;
    WakelockPlus.disable();
    
    _streamHealthTimer?.cancel();
    _searchTimer?.cancel();
    _remoteStreamSubscription?.cancel();
    _disconnectSubscription?.cancel();
    _matchSubscription?.cancel();
    _localStreamSubscription?.cancel();
    _leaveRandomPool();
    _endCurrentCall();
    _disposeLocalStream();
  }

  void _disposeLocalStream() {
    _localRenderer.srcObject = null;
  }

  Future<void> _initCamera() async {
    // Allow reinitialization if not tab active
    if (!_isTabActive) return;
    
    // Skip if already ready and we have a valid stream
    if (_isCameraReady && _webrtcService.currentLocalStream != null) {
      // Verify stream is still valid
      final tracks = _webrtcService.currentLocalStream!.getVideoTracks();
      if (tracks.isNotEmpty && tracks.first.enabled != null) {
        // Stream is valid, just update renderer
        _localRenderer.srcObject = _webrtcService.currentLocalStream;
        return;
      }
      // Stream is invalid, force reinitialization
      _isCameraReady = false;
    }
    
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    _hasPermissions = statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;

    if (!_hasPermissions) {
      if (mounted) {
        setState(() {
          _statusText = 'Camera permission required';
        });
      }
      return;
    }

    try {
      await _webrtcService.initializeLocalStream();
      
      _localRenderer.srcObject = _webrtcService.currentLocalStream;

      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _statusText = 'Tap Start to find someone';
          _isMuted = !_webrtcService.isMicEnabled;
          _isCameraOff = !_webrtcService.isCameraEnabled;
        });
      }
      
      // Setup all stream listeners
      _setupStreamListeners();
      
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = 'Failed to access camera';
        });
      }
    }
  }

  /// Setup stream listeners - call this before starting WebRTC connection
  void _setupStreamListeners() {
    debugPrint('🎧 Setting up stream listeners');
    
    // Listen for local stream changes
    _localStreamSubscription?.cancel();
    _localStreamSubscription = _webrtcService.localStream.listen((stream) {
      debugPrint('📹 Local stream updated: ${stream.getTracks().length} tracks');
      if (mounted && _isTabActive) {
        _localRenderer.srcObject = stream;
      }
    });
    
    // Listen for remote stream
    _remoteStreamSubscription?.cancel();
    _remoteStreamSubscription = _webrtcService.remoteStream.listen((stream) {
      debugPrint('📹 Remote stream received! tracks=${stream.getTracks().length}');
      debugPrint('📹 Video tracks: ${stream.getVideoTracks().length}');
      debugPrint('📹 Audio tracks: ${stream.getAudioTracks().length}');
      
      // Ensure audio tracks are enabled
      for (var track in stream.getAudioTracks()) {
        track.enabled = true;
        debugPrint('📹 Audio track enabled: ${track.enabled}');
      }
      
      // Ensure video tracks are enabled
      for (var track in stream.getVideoTracks()) {
        track.enabled = true;
        debugPrint('📹 Video track enabled: ${track.enabled}');
      }
      
      if (mounted && _isTabActive) {
        debugPrint('✅ Setting remote stream to renderer');
        _successfulConnectionCount++;
        
        WakelockPlus.enable();
        
        setState(() {
          _remoteRenderer.srcObject = stream;
          _isConnected = true;
          _isConnecting = false;
          _isSearching = false;
          _isUIVisible = true;
          _statusText = 'Connected!';
          _isMuted = !_webrtcService.isMicEnabled;
          _isCameraOff = !_webrtcService.isCameraEnabled;
        });
        _startUIAutoHideTimer();
      }
    });
    
    // Listen for disconnect
    _disconnectSubscription?.cancel();
    _disconnectSubscription = _webrtcService.remoteDisconnect.listen((disconnected) {
      debugPrint('📹 Remote disconnect signal: $disconnected');
      if (disconnected && mounted && _isTabActive) {
        _onRemoteDisconnect();
      }
    });
    
    debugPrint('🎧 Stream listeners setup complete');
  }

  void _onRemoteDisconnect() {
    if (_isConnecting) {
      _showSnackBar('Connection failed. Trying again...');
    } else {
      _showSnackBar('Stranger disconnected');
    }
    _skipToNext();
  }

  bool _shouldShowAdAfterConnections() {
    return _successfulConnectionCount > 0 && 
           _successfulConnectionCount % _adAfterConnections == 0;
  }

  /// Join random pool and wait for match
  Future<void> _startSearching() async {
    debugPrint('🔎 _startSearching called - isTabActive=$_isTabActive, isConnecting=$_isConnecting, isConnected=$_isConnected, isSearching=$_isSearching');
    
    // Reset manual stop flag when user starts searching
    _manuallyStopped = false;
    
    if (!_isTabActive || _isConnecting || _isConnected) {
      debugPrint('🔎 _startSearching: Aborted due to state check');
      return;
    }
    if (_adService.isShowingAd) {
      debugPrint('🔎 _startSearching: Aborted - ad is showing');
      return;
    }
    
    if (!_hasPermissions) {
      _showSnackBar('Please grant camera and microphone permissions');
      await _initCamera();
      return;
    }
    
    // Verify local stream is valid before starting
    if (_webrtcService.currentLocalStream == null) {
      _showSnackBar('Initializing camera...');
      _isCameraReady = false;
      await _initCamera();
      if (!_isCameraReady) {
        _showSnackBar('Failed to initialize camera');
        return;
      }
    }

    // Show ad after every 3 successful connections
    if (_shouldShowAdAfterConnections()) {
      setState(() {
        _statusText = 'Loading...';
      });
      
      await _adService.showInterstitialAd();
      
      if (!_isTabActive || !mounted) return;
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // End any existing call
    if (_currentRoomId != null) {
      await _webrtcService.endCall(_currentRoomId!);
      _currentRoomId = null;
    }
    
    // Reset WebRTC connection state but keep local stream
    debugPrint('📹 _startSearching: Resetting connection without stream reinit');
    await _webrtcService.resetConnectionWithoutStreamReinit();
    _clearRemoteRenderer();
    
    // Ensure local stream is still valid after reset
    await _webrtcService.ensureLocalStreamReady();
    debugPrint('📹 _startSearching: Stream ready, proceeding to search');
    
    await Future.delayed(const Duration(milliseconds: 100));

    if (!mounted || !_isTabActive) return;

    setState(() {
      _isSearching = true;
      _isConnected = false;
      _isConnecting = false;
      _connectedUserId = null;
      _statusText = 'Searching for someone...';
    });

    // Simply join pool with waiting status
    debugPrint('🚀 Joining random_pool as: $myUserId with status: waiting');
    await _database.child('random_pool/$myUserId').set({
      'joinedAt': ServerValue.timestamp,
      'status': 'waiting',
    });

    _findMatch();
    _listenForMatchRequests();
  }

  void _clearRemoteRenderer() {
    _currentSessionId = null;
    WakelockPlus.disable();
    
    if (_remoteRenderer.srcObject != null) {
      try {
        _remoteRenderer.srcObject!.getTracks().forEach((track) {
          track.stop();
        });
      } catch (e) {
        // Ignore
      }
      _remoteRenderer.srcObject = null;
    }
    
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _connectedUserId = null;
      });
    }
  }

  void _findMatch() {
    _searchTimer?.cancel();
    _checkForMatch();
    
    _searchTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!_isSearching || !_isTabActive || _isConnected || _isConnecting || _adService.isShowingAd) {
        timer.cancel();
        return;
      }
      await _checkForMatch();
    });
  }

  Future<void> _checkForMatch() async {
    if (!_isSearching || !_isTabActive || _isConnected || _isConnecting) return;

    try {
      final snapshot = await _database.child('random_pool').get();
      
      if (!snapshot.exists || snapshot.value == null) {
        debugPrint('🔍 Pool is empty');
        return;
      }
      
      final poolMap = snapshot.value as Map<dynamic, dynamic>;
      final now = DateTime.now().millisecondsSinceEpoch;
      debugPrint('🔍 Pool has ${poolMap.length} users');
      
      // Debug: Print all users and their status, and clean up stale matched users
      for (var entry in poolMap.entries) {
        final uid = entry.key.toString();
        final data = entry.value as Map<dynamic, dynamic>;
        final joinedAt = data['joinedAt'] as int? ?? 0;
        final status = data['status']?.toString() ?? 'unknown';
        final age = (now - joinedAt) ~/ 1000; // seconds
        
        debugPrint('   👤 $uid: status=$status, age=${age}s');
        
        // Clean up stale matched entries (matched for more than 30 seconds without connecting)
        if (status == 'matched' && age > 30 && uid != myUserId) {
          debugPrint('   🧹 Cleaning stale matched user: $uid');
          await _database.child('random_pool/$uid').remove();
        }
      }
      
      // Re-fetch after cleanup
      final freshSnapshot = await _database.child('random_pool').get();
      if (!freshSnapshot.exists || freshSnapshot.value == null) {
        debugPrint('🔍 Pool empty after cleanup');
        return;
      }
      final freshPoolMap = freshSnapshot.value as Map<dynamic, dynamic>;
      
      // Simple: Find any user with status 'waiting' who is not me and not skipped
      String? targetUserId;
      for (var entry in freshPoolMap.entries) {
        final odId = entry.key.toString();
        if (odId == myUserId) continue;
        if (_skippedUsersThisSession.contains(odId)) continue;
        
        final data = entry.value as Map<dynamic, dynamic>;
        if (data['status'] == 'waiting') {
          targetUserId = odId;
          break;
        }
      }
      
      if (targetUserId == null) {
        debugPrint('🔍 No waiting users found (excluding myself and ${_skippedUsersThisSession.length} skipped)');
        return;
      }
      
      debugPrint('🔍 Found waiting user: $targetUserId, attempting to claim match...');
      
      // Use transaction to avoid race condition where both users try to match each other
      final targetRef = _database.child('random_pool/$targetUserId');
      final result = await targetRef.runTransaction((currentData) {
        if (currentData == null) {
          return Transaction.abort();
        }
        
        final data = Map<String, dynamic>.from(currentData as Map);
        
        // Only proceed if target is still waiting
        if (data['status'] != 'waiting') {
          debugPrint('🔍 Target no longer waiting, aborting');
          return Transaction.abort();
        }
        
        // Claim the match
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final roomId = '${myUserId}_${targetUserId}_$timestamp';
        
        data['status'] = 'matched';
        data['matchedWith'] = myUserId;
        data['roomId'] = roomId;
        
        return Transaction.success(data);
      });
      
      if (!result.committed || result.snapshot.value == null) {
        debugPrint('🔍 Failed to claim match (someone else got them first)');
        return;
      }
      
      // Get the roomId from the successful transaction
      final matchData = result.snapshot.value as Map<dynamic, dynamic>;
      final roomId = matchData['roomId'].toString();
      
      // Now update my own status
      await _database.child('random_pool/$myUserId').update({
        'status': 'matched',
        'matchedWith': targetUserId,
        'roomId': roomId,
      });
      
      debugPrint('✅ Match claimed successfully: $roomId');
      
      // I am the caller
      _searchTimer?.cancel();
      _initiateConnection(targetUserId, isCaller: true, roomId: roomId);
      
    } catch (e) {
      debugPrint('❌ Error: $e');
    }
  }

  void _listenForMatchRequests() {
    _matchSubscription?.cancel();
    
    _matchSubscription = _database
        .child('random_pool/$myUserId')
        .onValue
        .listen((event) async {
      if (!_isSearching || _isConnected || _isConnecting) return;
      
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        
        // Someone matched with me
        if (data['status'] == 'matched' && data['matchedWith'] != null && data['roomId'] != null) {
          final matchedUserId = data['matchedWith'].toString();
          final roomId = data['roomId'].toString();
          
          // Check if I initiated this match (I am caller) or someone else did (I am callee)
          // If roomId starts with my ID, I am the caller - already handling in _checkForMatch
          // If roomId starts with other user's ID, I am the callee
          if (!roomId.startsWith(myUserId)) {
            debugPrint('👂 Someone matched with me: $matchedUserId, room: $roomId');
            _searchTimer?.cancel();
            _initiateConnection(matchedUserId, isCaller: false, roomId: roomId);
          }
        }
      }
    });
  }

  Future<void> _initiateConnection(String remoteUserId, {required bool isCaller, String? roomId}) async {
    debugPrint('📹 _initiateConnection: Starting with remoteUserId=$remoteUserId, isCaller=$isCaller, roomId=$roomId');
    
    if (!_isTabActive || _isConnected || _isConnecting || _adService.isShowingAd) {
      debugPrint('📹 _initiateConnection: Aborted - isTabActive=$_isTabActive, isConnected=$_isConnected, isConnecting=$_isConnecting');
      return;
    }
    
    // Check if user was skipped
    if (_skippedUsersThisSession.contains(remoteUserId)) {
      debugPrint('📹 _initiateConnection: User was skipped, moving to next');
      _skipToNext();
      return;
    }
    
    _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
    
    setState(() {
      _statusText = 'Connecting...';
      _connectedUserId = remoteUserId;
      _isSearching = false;
      _isConnecting = true;
    });

    try {
      _currentRoomId = roomId;
      _sessionManager.currentRoomId = _currentRoomId;
      
      if (_currentRoomId == null) {
        throw Exception('Room ID is null');
      }
      
      // Re-setup stream listeners before starting WebRTC connection
      debugPrint('📹 _initiateConnection: Setting up stream listeners');
      _setupStreamListeners();
      
      // Ensure local stream is ready before creating offer/handling offer
      debugPrint('📹 _initiateConnection: Ensuring local stream is ready');
      await _webrtcService.ensureLocalStreamReady();
      
      // Update local renderer with current stream
      if (_webrtcService.currentLocalStream != null) {
        _localRenderer.srcObject = _webrtcService.currentLocalStream;
      }
      
      if (isCaller) {
        debugPrint('📹 _initiateConnection: Creating offer as caller');
        await _webrtcService.createOffer(_currentRoomId!, remoteUserId: remoteUserId);
      } else {
        debugPrint('📹 _initiateConnection: Handling offer as callee');
        await _webrtcService.handleOffer(_currentRoomId!, remoteUserId);
      }
      
      debugPrint('📹 _initiateConnection: WebRTC setup complete');

    } catch (e) {
      debugPrint('❌ _initiateConnection: Error - $e');
      if (mounted && _isTabActive) {
        setState(() {
          _isConnecting = false;
        });
        _showSnackBar('Connection failed. Trying again...');
        _skipToNext();
      }
    }
  }

  Future<void> _leaveRandomPool() async {
    debugPrint('🚪 Leaving random pool...');
    try {
      await _database.child('random_pool/$myUserId').remove();
    } catch (e) {
      debugPrint('🚪 Error: $e');
    }
  }

  Future<void> _endCurrentCall() async {
    debugPrint('📞 _endCurrentCall: Starting cleanup...');
    
    _clearRemoteRenderer();
    
    _searchTimer?.cancel();
    _matchSubscription?.cancel();
    
    if (_currentRoomId != null) {
      debugPrint('📞 _endCurrentCall: Cleaning up room $_currentRoomId');
      try {
        await _webrtcService.endCall(_currentRoomId!);
        await _database.child('random_matches/$_currentRoomId').remove();
        await _database.child('webrtc_signaling/$_currentRoomId').remove();
      } catch (e) {
        debugPrint('📞 _endCurrentCall: Error during cleanup - $e');
      }
      _currentRoomId = null;
    }
    _sessionManager.clearCallSession();
    debugPrint('📞 _endCurrentCall: Cleanup complete');
  }

  Future<void> _skipToNext() async {
    debugPrint('⏭️ _skipToNext called');
    
    // Add current connected user to skipped list
    if (_connectedUserId != null) {
      _skippedUsersThisSession.add(_connectedUserId!);
      debugPrint('⏭️ Added $_connectedUserId to skipped list');
    }
    
    _searchTimer?.cancel();
    _matchSubscription?.cancel();
    
    _clearRemoteRenderer();
    
    await _endCurrentCall();
    await _leaveRandomPool();
    
    if (!mounted || !_isTabActive) {
      debugPrint('⏭️ Aborted - not mounted or tab not active');
      return;
    }
    
    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _isSearching = false;  // Reset this too!
      _connectedUserId = null;
      _statusText = 'Searching for someone...';
    });
    
    // Reinitialize local stream for fresh connection
    debugPrint('⏭️ Reinitializing stream for next connection...');
    await _webrtcService.ensureLocalStreamReady();
    
    // Longer delay for proper cleanup
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (!mounted || !_isTabActive) return;
    
    // Only auto-start if user didn't manually stop
    if (_manuallyStopped) {
      debugPrint('⏭️ Not auto-starting - user manually stopped');
      setState(() {
        _statusText = 'Tap Start to find someone';
      });
      return;
    }
    
    debugPrint('⏭️ Starting new search...');
    _startSearching();
  }

  void _stopSearching() {
    debugPrint('🛑 _stopSearching: Manual stop by user');
    _manuallyStopped = true;  // User manually stopped
    
    _searchTimer?.cancel();
    _matchSubscription?.cancel();
    _leaveRandomPool();
    
    // Clear skipped users when stopping search
    _skippedUsersThisSession.clear();
    
    if (mounted) {
      setState(() {
        _isSearching = false;
        _isConnecting = false;
        _statusText = 'Tap Start to find someone';
      });
    }
  }

  void _toggleMute() {
    _webrtcService.toggleMicrophone();
    setState(() {
      _isMuted = !_webrtcService.isMicEnabled;
    });
  }

  void _toggleCamera() {
    _webrtcService.toggleCamera();
    setState(() {
      _isCameraOff = !_webrtcService.isCameraEnabled;
    });
  }

  void _switchCamera() {
    setState(() {
      _isFrontCamera = !_isFrontCamera;
    });
    _webrtcService.switchCamera();
  }

  bool _isSpeakerOn = false;
  
  Future<void> _toggleSpeaker() async {
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
    if (_isSpeakerOn) {
      await _webrtcService.setAudioOutputToSpeaker();
    } else {
      await _webrtcService.setAudioOutputToDefault();
    }
  }

  void _startUIAutoHideTimer() {
    _uiHideTimer?.cancel();
    if (_isConnected) {
      _uiHideTimer = Timer(_uiHideDelay, () {
        if (mounted && _isConnected) {
          setState(() {
            _isUIVisible = false;
          });
        }
      });
    }
  }

  void _showUI() {
    setState(() {
      _isUIVisible = true;
    });
    _startUIAutoHideTimer();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.getPrimaryColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final secondaryColor = AppTheme.getSecondaryColor(context);
    // Use a visible gray color for control buttons (works on black video background)
    final controlButtonColor = Colors.grey.shade700;
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final errorColor = AppTheme.getErrorColor(context);
    final overlayColor = AppTheme.getOverlayColor(context);
    
    return Scaffold(
      backgroundColor: AppTheme.getCallScreenBackground(context),
      body: GestureDetector(
        onTap: () {
          // Toggle UI visibility when connected
          if (_isConnected) {
            if (_isUIVisible) {
              setState(() {
                _isUIVisible = false;
              });
            } else {
              _showUI();
            }
          }
        },
        child: SafeArea(
          child: Stack(
            children: [
              // Video layout - changes based on _videoLayout preference
              // Apply layout in all states (not just connected)
              if (_videoLayout == RandomVideoLayoutType.omegle)
                // Omegle style - Vertical split
                _buildOmegleLayout(controlButtonColor, onSurfaceColor, overlayColor, primaryColor)
              else
                // WhatsApp style (default) - Full screen remote + PiP local
                ..._buildWhatsAppLayout(controlButtonColor, onSurfaceColor, overlayColor, primaryColor),

              // Status badge - Top left
              Positioned(
                top: 16,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isConnected 
                        ? secondaryColor.withOpacity(0.9)
                        : (_isSearching || _isConnecting ? primaryColor : controlButtonColor.withOpacity(0.8)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isConnected ? Icons.person : ((_isSearching || _isConnecting) ? Icons.search : Icons.person_outline),
                        color: AppTheme.getOnPrimaryColor(context),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isConnected ? 'Connected' : (_isConnecting ? 'Connecting...' : (_isSearching ? 'Searching...' : 'Ready')),
                        style: TextStyle(
                          color: AppTheme.getOnPrimaryColor(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Skip hint - Top right (when connected or searching)
              if ((_isConnected || _isSearching) && _isUIVisible)
                Positioned(
                  top: 320,
                  right: _isCameraReady && _localRenderer.srcObject != null ? 8 : 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: overlayColor.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.swipe_left,
                          color: onSurfaceColor.withOpacity(0.8),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Swipe to skip',
                          style: TextStyle(
                            color: onSurfaceColor.withOpacity(0.8),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Banner - Top right corner (controlled from admin panel)
              if (_showBanner && !_isConnected && !_isSearching && _isUIVisible)
                Positioned(
                  top: 10,
                  right: 16,
                  child: Container(
                    height: 55,
                    width: 220,
                    decoration: BoxDecoration(
                      color: _bannerColor,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: overlayColor.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        'Banner',
                        style: TextStyle(
                          color: AppTheme.getOnPrimaryColor(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),

              // Controls overlay - Bottom
              if (!_isConnected || _isUIVisible)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          overlayColor.withOpacity(0.9),
                          overlayColor.withOpacity(0.5),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Status text
                        if (!_isConnected)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              _statusText,
                              style: TextStyle(
                                color: onSurfaceColor.withOpacity(0.8),
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),

                        // Action buttons - Scrollable to prevent overflow
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // When connected - show call controls
                              if (_isConnected) ...[
                                // Mute button (no label)
                                _buildControlButton(
                                  icon: _isMuted ? Icons.mic_off : Icons.mic,
                                  label: '', // No text label
                                  color: _isMuted ? errorColor : controlButtonColor,
                                  onPressed: _toggleMute,
                                ),
                                const SizedBox(width: 12),
                                
                                // Speaker toggle (no label)
                                _buildControlButton(
                                  icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                                  label: '', // No text label
                                  color: _isSpeakerOn ? secondaryColor : controlButtonColor,
                                  onPressed: _toggleSpeaker,
                                ),
                                const SizedBox(width: 12),
                                
                                // Next/Skip button (with label)
                                _buildControlButton(
                                  icon: Icons.skip_next,
                                  label: 'Next',
                                  color: primaryColor,
                                  onPressed: _skipToNext,
                                  large: true,
                                ),
                                const SizedBox(width: 12),
                                
                                // Camera toggle (no label)
                                _buildControlButton(
                                  icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
                                  label: '', // No text label
                                  color: _isCameraOff ? errorColor : controlButtonColor,
                                  onPressed: _toggleCamera,
                                ),
                                const SizedBox(width: 12),
                                
                                // Flip camera (no label)
                                _buildControlButton(
                                  icon: Icons.flip_camera_ios,
                                  label: '', // No text label
                                  color: controlButtonColor,
                                  onPressed: _switchCamera,
                                ),
                                const SizedBox(width: 12),
                                
                                // Layout toggle (no label)
                                _buildControlButton(
                                  icon: _videoLayout == RandomVideoLayoutType.whatsapp 
                                      ? Icons.view_agenda 
                                      : Icons.picture_in_picture,
                                  label: '', // No text label
                                  color: controlButtonColor,
                                  onPressed: _toggleVideoLayout,
                                ),
                              ],
                              
                              // When not connected - show Start/Stop and Layout toggle
                              if (!_isConnected) ...[
                                // Layout toggle button (always visible when not connected)
                                _buildControlButton(
                                  icon: _videoLayout == RandomVideoLayoutType.whatsapp 
                                      ? Icons.view_agenda 
                                      : Icons.picture_in_picture,
                                  label: _videoLayout == RandomVideoLayoutType.whatsapp ? 'Split' : 'PiP',
                                  color: controlButtonColor,
                                  onPressed: _toggleVideoLayout,
                                ),
                                const SizedBox(width: 20),
                                
                                // Start button (when not searching)
                                if (!_isSearching && !_isConnecting)
                                  _buildControlButton(
                                    icon: Icons.play_arrow,
                                    label: 'Start',
                                    color: primaryColor,
                                    onPressed: _startSearching,
                                    large: true,
                                  ),
                                
                                // Stop button (when searching)
                                if (_isSearching || _isConnecting)
                                  _buildControlButton(
                                    icon: Icons.stop,
                                    label: 'Stop',
                                    color: errorColor,
                                    onPressed: _stopSearching,
                                    large: true,
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Build WhatsApp style layout (full screen remote + PiP local)
  List<Widget> _buildWhatsAppLayout(Color buttonColor, Color onSurfaceColor, Color overlayColor, Color primaryColor) {
    return [
      // Full screen - Remote video OR Loading/Placeholder
      Positioned.fill(
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            // Swipe right to left to skip (when connected or searching)
            if (details.primaryVelocity != null && details.primaryVelocity! < -500) {
              if (_isConnected || _isSearching) {
                _skipToNext();
              }
            }
          },
          child: Container(
            color: buttonColor,
            child: _isConnected && _remoteRenderer.srcObject != null
                ? RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_isSearching || _isConnecting)
                          Column(
                            children: [
                              SizedBox(
                                width: 80,
                                height: 80,
                                child: CircularProgressIndicator(
                                  color: primaryColor,
                                  strokeWidth: 4,
                                ),
                              ),
                              const SizedBox(height: 32),
                              Text(
                                _isConnecting ? 'Connecting...' : 'Finding someone...',
                                style: TextStyle(
                                  color: onSurfaceColor.withOpacity(0.8),
                                  fontSize: 22,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Please wait',
                                style: TextStyle(
                                  color: onSurfaceColor.withOpacity(0.5),
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          )
                        else
                          Column(
                            children: [
                              Icon(
                                Icons.video_chat_outlined,
                                size: 100,
                                color: onSurfaceColor.withOpacity(0.3),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                'Random Video Chat',
                                style: TextStyle(
                                  color: onSurfaceColor.withOpacity(0.6),
                                  fontSize: 24,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Tap Start to connect with a stranger',
                                style: TextStyle(
                                  color: onSurfaceColor.withOpacity(0.4),
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),
        ),
      ),

      // Local video - Small window in corner (PiP style)
      if (_isCameraReady && _localRenderer.srcObject != null)
        Positioned(
          top: 68,
          right: 16,
          child: GestureDetector(
            onTap: _switchCamera,
            child: Container(
              width: 120,
              height: 160,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: onSurfaceColor.withOpacity(0.3),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: overlayColor.withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: !_isCameraOff
                    ? RTCVideoView(
                        _localRenderer,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : Container(
                        color: buttonColor,
                        child: Center(
                          child: Icon(
                            Icons.videocam_off,
                            size: 32,
                            color: onSurfaceColor.withOpacity(0.5),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
    ];
  }

  // Build Omegle style layout (vertical split - remote top, local bottom)
  Widget _buildOmegleLayout(Color buttonColor, Color onSurfaceColor, Color overlayColor, Color primaryColor) {
    return Positioned.fill(
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          // Swipe right to left to skip
          if (details.primaryVelocity != null && details.primaryVelocity! < -500) {
            if (_isConnected || _isSearching) {
              _skipToNext();
            }
          }
        },
        child: Column(
          children: [
            // Remote video - Top half
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: buttonColor,
                  border: Border(
                    bottom: BorderSide(
                      color: onSurfaceColor.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                ),
                child: _isConnected && _remoteRenderer.srcObject != null
                    ? RTCVideoView(
                        _remoteRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : Center(
                        child: _isSearching || _isConnecting
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 60,
                                    height: 60,
                                    child: CircularProgressIndicator(
                                      color: primaryColor,
                                      strokeWidth: 3,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _isConnecting ? 'Connecting...' : 'Finding...',
                                    style: TextStyle(
                                      color: onSurfaceColor.withOpacity(0.7),
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.person,
                                    size: 60,
                                    color: onSurfaceColor.withOpacity(0.3),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Stranger',
                                    style: TextStyle(
                                      color: onSurfaceColor.withOpacity(0.4),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                      ),
              ),
            ),
            // Local video - Bottom half
            Expanded(
              child: Container(
                width: double.infinity,
                color: buttonColor,
                child: _isCameraReady && _localRenderer.srcObject != null && !_isCameraOff
                    ? RTCVideoView(
                        _localRenderer,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.videocam_off,
                              size: 60,
                              color: onSurfaceColor.withOpacity(0.3),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'You',
                              style: TextStyle(
                                color: onSurfaceColor.withOpacity(0.4),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
    bool large = false,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: large ? 60 : 48,
            height: large ? 60 : 48,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.4),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: AppTheme.getOnPrimaryColor(context),
              size: large ? 30 : 22,
            ),
          ),
          // Only show label if not empty
          if (label.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: AppTheme.getOnSurfaceColor(context).withOpacity(0.8),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

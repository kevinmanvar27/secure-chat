import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/user_service.dart';
import '../services/session_manager.dart';
import '../services/webrtc_service.dart';
import '../services/ad_service.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

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
  bool _isMuted = false; // Default unmuted for random calls
  bool _isCameraOff = false;
  bool _isFrontCamera = true; // Track front/back camera for mirror
  bool _isConnecting = false; // Prevent multiple connection attempts
  
  // Successful connection counter for ads (show ad after every 3 connections)
  int _successfulConnectionCount = 0;
  static const int _adAfterConnections = 3;
  
  // Auto-hide UI when connected
  bool _isUIVisible = true;
  Timer? _uiHideTimer;
  static const Duration _uiHideDelay = Duration(seconds: 4);
  
  String _statusText = 'Tap Start to find someone';
  String? _connectedUserId;
  String? _currentRoomId;
  
  Timer? _searchTimer;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _disconnectSubscription;
  StreamSubscription? _matchSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Don't initialize renderers here - do it when tab becomes active
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiHideTimer?.cancel();
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
      _initCamera();
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
      
      _initCamera();
    }
  }

  /// Called when tab becomes inactive
  /// Returns true if tab can be switched, false if user cancelled
  Future<bool> onTabInactive() async {
    if (_isTabActive) {
      // If connected, ask for confirmation before switching
      if (_isConnected) {
        final shouldSwitch = await _showTabSwitchConfirmation();
        if (!shouldSwitch) {
          return false; // User cancelled, don't switch tab
        }
      }
      _isTabActive = false;
      _stopEverything();
    }
    return true;
  }

  /// Show confirmation dialog before switching tab during call
  Future<bool> _showTabSwitchConfirmation() async {
    if (!mounted) return true;
    
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.deepPurple, size: 28),
            SizedBox(width: 12),
            Text('End Call?', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          'You are currently in a call. Switching tabs will end the call. Are you sure?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay', style: TextStyle(color: Colors.green)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End Call', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    return result ?? false;
  }

  void _stopEverything() {
    _endCurrentCall();
    _stopSearching();
    _disposeLocalStream();
    setState(() {
      _isCameraReady = false;
      _isConnected = false;
      _isConnecting = false;
      _connectedUserId = null;
      _statusText = 'Tap Start to find someone';
    });
  }

  void _cleanup() {
    _searchTimer?.cancel();
    _remoteStreamSubscription?.cancel();
    _disconnectSubscription?.cancel();
    _matchSubscription?.cancel();
    _leaveRandomPool();
    _endCurrentCall();
    _disposeLocalStream();
  }

  void _disposeLocalStream() {
    _localRenderer.srcObject = null;
  }

  Future<void> _initCamera() async {
    if (_isCameraReady || !_isTabActive) return;
    
    // Request permissions
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
      // Initialize WebRTC local stream
      await _webrtcService.initializeLocalStream();
      
      // Set local renderer
      _localRenderer.srcObject = _webrtcService.currentLocalStream;

      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _statusText = 'Tap Start to find someone';
          // Sync mic/camera state from WebRTC
          _isMuted = !_webrtcService.isMicEnabled;
          _isCameraOff = !_webrtcService.isCameraEnabled;
        });
      }
      
      // Listen for remote stream
      _remoteStreamSubscription?.cancel();
      _remoteStreamSubscription = _webrtcService.remoteStream.listen((stream) {
        if (mounted && _isTabActive) {
          // Increment successful connection count
          _successfulConnectionCount++;
          
          setState(() {
            _remoteRenderer.srcObject = stream;
            _isConnected = true;
            _isConnecting = false;
            _isUIVisible = true; // Show UI when first connected
            _statusText = 'Connected!';
            // Sync mic/camera state again when connected
            _isMuted = !_webrtcService.isMicEnabled;
            _isCameraOff = !_webrtcService.isCameraEnabled;
          });
          // Start auto-hide timer
          _startUIAutoHideTimer();
        }
      });
      
      // Listen for disconnect
      _disconnectSubscription?.cancel();
      _disconnectSubscription = _webrtcService.remoteDisconnect.listen((disconnected) {
        if (disconnected && mounted && _isTabActive) {
          _onRemoteDisconnect();
        }
      });
      
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = 'Failed to access camera';
        });
      }
    }
  }

  void _onRemoteDisconnect() {
    if (_isConnecting) {
      // Connection failed during setup
      _showSnackBar('Connection failed. Trying again...');
    } else {
      _showSnackBar('Stranger disconnected');
    }
    _skipToNext();
  }

  /// Check if should show ad (after every 3 successful connections)
  bool _shouldShowAdAfterConnections() {
    return _successfulConnectionCount > 0 && 
           _successfulConnectionCount % _adAfterConnections == 0;
  }

  /// Join random pool and wait for match
  Future<void> _startSearching() async {
    if (!_isTabActive || _isConnecting) return;
    
    // Don't start if ad is showing
    if (_adService.isShowingAd) return;
    
    if (!_hasPermissions) {
      _showSnackBar('Please grant camera and microphone permissions');
      await _initCamera();
      return;
    }

    // Show ad after every 3 successful connections (not before first search)
    if (_shouldShowAdAfterConnections()) {
      setState(() {
        _statusText = 'Loading...';
      });
      
      // Show ad and WAIT for it to complete before proceeding
      await _adService.showInterstitialAd();
      
      // Check if tab is still active after ad
      if (!_isTabActive || !mounted) return;
      
      // Small delay after ad closes
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // IMPORTANT: Clear remote renderer completely before new search
    _clearRemoteRenderer();

    setState(() {
      _isSearching = true;
      _isConnected = false;
      _isConnecting = false;
      _connectedUserId = null;
      _statusText = 'Searching for someone...';
    });

    // Join random pool with timestamp
    await _database.child('random_pool/$myUserId').set({
      'joinedAt': ServerValue.timestamp,
      'status': 'waiting',
    });

    // Start looking for matches
    _findMatch();
    
    // Also listen for incoming match requests
    _listenForMatchRequests();
  }

  /// Clear remote renderer to prevent freeze/glitch
  void _clearRemoteRenderer() {
    // Completely reset remote renderer
    if (_remoteRenderer.srcObject != null) {
      _remoteRenderer.srcObject?.getTracks().forEach((track) {
        track.stop();
      });
      _remoteRenderer.srcObject = null;
    }
    
    // Force UI update
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _connectedUserId = null;
      });
    }
  }

  /// Find another user in the pool and initiate connection
  void _findMatch() {
    _searchTimer?.cancel();
    
    // First immediate check, then periodic
    _checkForMatch();
    
    _searchTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!_isSearching || !_isTabActive || _isConnected || _isConnecting || _adService.isShowingAd) {
        timer.cancel();
        return;
      }
      await _checkForMatch();
    });
  }

  /// Check for available users and try to match
  Future<void> _checkForMatch() async {
    // Don't check if ad is showing
    if (!_isSearching || !_isTabActive || _isConnected || _isConnecting || _adService.isShowingAd) return;

    try {
      // Get all users in random pool
      final snapshot = await _database.child('random_pool').get();
      
      if (!snapshot.exists || snapshot.value == null) return;
      
      final poolMap = snapshot.value as Map<dynamic, dynamic>;
      
      // Find waiting users (not myself, not already matched)
      final waitingUsers = poolMap.entries
          .where((e) => e.key != myUserId)
          .where((e) {
            final data = e.value as Map<dynamic, dynamic>;
            return data['status'] == 'waiting';
          })
          .map((e) => e.key.toString())
          .toList();
      
      if (waitingUsers.isEmpty) return;
      
      // Pick random user
      waitingUsers.shuffle();
      final targetUserId = waitingUsers.first;
      
      // Try to match with this user (atomic operation)
      final matchResult = await _tryMatch(targetUserId);
      
      if (matchResult && _isSearching && _isTabActive && !_isConnected && !_isConnecting) {
        _searchTimer?.cancel();
        _initiateConnection(targetUserId, isCaller: true);
      }
    } catch (e) {
      // Continue searching
    }
  }

  /// Try to match with a user atomically
  Future<bool> _tryMatch(String targetUserId) async {
    try {
      // Create a unique room ID (sorted to ensure both users get same ID)
      final users = [myUserId, targetUserId]..sort();
      final roomId = '${users[0]}_${users[1]}';
      
      // Try to claim this match
      final matchRef = _database.child('random_matches/$roomId');
      
      final result = await matchRef.runTransaction((data) {
        if (data != null) {
          // Match already exists
          return Transaction.abort();
        }
        
        return Transaction.success({
          'user1': myUserId,
          'user2': targetUserId,
          'createdAt': ServerValue.timestamp,
          'initiator': myUserId,
        });
      });
      
      if (result.committed) {
        // Update both users' status
        await _database.child('random_pool/$myUserId/status').set('matched');
        await _database.child('random_pool/$myUserId/matchedWith').set(targetUserId);
        await _database.child('random_pool/$myUserId/roomId').set(roomId);
        
        await _database.child('random_pool/$targetUserId/status').set('matched');
        await _database.child('random_pool/$targetUserId/matchedWith').set(myUserId);
        await _database.child('random_pool/$targetUserId/roomId').set(roomId);
        
        return true;
      }
      
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Listen for incoming match requests
  void _listenForMatchRequests() {
    _matchSubscription?.cancel();
    
    _matchSubscription = _database
        .child('random_pool/$myUserId')
        .onValue
        .listen((event) async {
      // Don't process match if ad is showing
      if (!_isSearching || !_isTabActive || _isConnected || _isConnecting || _adService.isShowingAd) return;
      
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        
        if (data['status'] == 'matched' && data['matchedWith'] != null) {
          final matchedUserId = data['matchedWith'].toString();
          final roomId = data['roomId']?.toString();
          final initiator = await _getMatchInitiator(roomId);
          
          // If I'm not the initiator, I'm the receiver
          if (initiator != null && initiator != myUserId) {
            _searchTimer?.cancel();
            _initiateConnection(matchedUserId, isCaller: false, roomId: roomId);
          }
        }
      }
    });
  }

  Future<String?> _getMatchInitiator(String? roomId) async {
    if (roomId == null) return null;
    try {
      final snapshot = await _database.child('random_matches/$roomId/initiator').get();
      return snapshot.value?.toString();
    } catch (e) {
      return null;
    }
  }

  /// Initiate WebRTC connection (auto-accept, no dialog)
  Future<void> _initiateConnection(String remoteUserId, {required bool isCaller, String? roomId}) async {
    // Don't connect if ad is showing
    if (!_isTabActive || _isConnected || _isConnecting || _adService.isShowingAd) return;
    
    setState(() {
      _statusText = 'Connecting...';
      _connectedUserId = remoteUserId;
      _isSearching = false;
      _isConnecting = true;
    });

    try {
      // Create room ID if not provided
      final users = [myUserId, remoteUserId]..sort();
      _currentRoomId = roomId ?? '${users[0]}_${users[1]}';
      _sessionManager.currentRoomId = _currentRoomId;
      
      if (isCaller) {
        // Create WebRTC offer directly (no call request dialog)
        await _webrtcService.createOffer(_currentRoomId!, remoteUserId: remoteUserId);
      } else {
        // Handle offer directly (auto-accept)
        await _webrtcService.handleOffer(_currentRoomId!, remoteUserId);
      }

    } catch (e) {
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
    try {
      // Remove from random pool
      await _database.child('random_pool/$myUserId').remove();
      
      // Clean up any match
      if (_currentRoomId != null) {
        await _database.child('random_matches/$_currentRoomId').remove();
      }
    } catch (e) {
      // Ignore
    }
  }

  Future<void> _endCurrentCall() async {
    // Clear remote renderer FIRST to prevent freeze
    _clearRemoteRenderer();
    
    if (_currentRoomId != null) {
      try {
        await _webrtcService.endCall(_currentRoomId!);
        await _database.child('random_matches/$_currentRoomId').remove();
      } catch (e) {
        // Ignore errors
      }
      _currentRoomId = null;
    }
    _sessionManager.clearCallSession();
  }

  Future<void> _skipToNext() async {
    // Clear remote renderer FIRST
    _clearRemoteRenderer();
    
    // End current call
    await _endCurrentCall();
    await _leaveRandomPool();
    
    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _connectedUserId = null;
      _statusText = 'Searching for someone...';
    });
    
    // Small delay to ensure cleanup is complete
    await Future.delayed(const Duration(milliseconds: 300));
    
    // Start searching again
    _startSearching();
  }

  void _stopSearching() {
    _searchTimer?.cancel();
    _matchSubscription?.cancel();
    _leaveRandomPool();
    
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
    // Sync state from actual WebRTC state
    setState(() {
      _isMuted = !_webrtcService.isMicEnabled;
    });
  }

  void _toggleCamera() {
    _webrtcService.toggleCamera();
    // Sync state from actual WebRTC state
    setState(() {
      _isCameraOff = !_webrtcService.isCameraEnabled;
    });
  }

  void _switchCamera() {
    // First toggle the mirror state, then switch camera
    setState(() {
      _isFrontCamera = !_isFrontCamera;
    });
    _webrtcService.switchCamera();
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
        backgroundColor: Colors.deepPurple.shade700,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
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
                    color: Colors.grey.shade900,
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
                                      const SizedBox(
                                        width: 80,
                                        height: 80,
                                        child: CircularProgressIndicator(
                                          color: Colors.purpleAccent,
                                          strokeWidth: 4,
                                        ),
                                      ),
                                      const SizedBox(height: 32),
                                      Text(
                                        _isConnecting ? 'Connecting...' : 'Finding someone...',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.8),
                                          fontSize: 22,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'Please wait',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.5),
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
                                        color: Colors.white.withOpacity(0.3),
                                      ),
                                      const SizedBox(height: 24),
                                      Text(
                                        'Random Video Chat',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.6),
                                          fontSize: 24,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'Tap Start to connect with a stranger',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.4),
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

              // Local video - Small window in corner (WhatsApp style)
              if (_isCameraReady && _localRenderer.srcObject != null)
                Positioned(
                  top: 60,
                  right: 16,
                  child: GestureDetector(
                    onTap: _switchCamera,
                    child: Container(
                      width: 120,
                      height: 160,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.3),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
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
                                color: Colors.grey.shade800,
                                child: Center(
                                  child: Icon(
                                    Icons.videocam_off,
                                    size: 32,
                                    color: Colors.white.withOpacity(0.5),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),

              // Status badge - Top left
              Positioned(
                top: 16,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isConnected 
                        ? Colors.green.withOpacity(0.9)
                        : (_isSearching || _isConnecting ? Colors.orange.withOpacity(0.9) : Colors.grey.withOpacity(0.8)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isConnected ? Icons.person : ((_isSearching || _isConnecting) ? Icons.search : Icons.person_outline),
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isConnected ? 'Connected' : (_isConnecting ? 'Connecting...' : (_isSearching ? 'Searching...' : 'Ready')),
                        style: const TextStyle(
                          color: Colors.white,
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
                  top: 16,
                  right: _isCameraReady && _localRenderer.srcObject != null ? 150 : 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.swipe_left,
                          color: Colors.white.withOpacity(0.8),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Swipe to skip',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 13,
                          ),
                        ),
                      ],
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
                          Colors.black.withOpacity(0.9),
                          Colors.black.withOpacity(0.5),
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
                                color: Colors.white.withOpacity(0.8),
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),

                        // Action buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // When connected - show call controls
                            if (_isConnected) ...[
                              // Mute button
                              _buildControlButton(
                                icon: _isMuted ? Icons.mic_off : Icons.mic,
                                label: _isMuted ? 'Unmute' : 'Mute',
                                color: _isMuted ? Colors.red : Colors.grey.shade700,
                                onPressed: _toggleMute,
                              ),
                              const SizedBox(width: 16),
                              
                              // Next/Skip button
                              _buildControlButton(
                                icon: Icons.skip_next,
                                label: 'Next',
                                color: Colors.green,
                                onPressed: _skipToNext,
                                large: true,
                              ),
                              const SizedBox(width: 16),
                              
                              // Camera toggle
                              _buildControlButton(
                                icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
                                label: _isCameraOff ? 'Show' : 'Hide',
                                color: _isCameraOff ? Colors.red : Colors.grey.shade700,
                                onPressed: _toggleCamera,
                              ),
                              const SizedBox(width: 16),
                              
                              // Flip camera
                              _buildControlButton(
                                icon: Icons.flip_camera_ios,
                                label: 'Flip',
                                color: Colors.grey.shade700,
                                onPressed: _switchCamera,
                              ),
                            ],
                            
                            // When not connected and not searching - show Start button
                            if (!_isConnected && !_isSearching && !_isConnecting)
                              _buildControlButton(
                                icon: Icons.play_arrow,
                                label: 'Start',
                                color: Colors.green,
                                onPressed: _startSearching,
                                large: true,
                              ),
                            
                            // When searching - show Stop button
                            if ((_isSearching || _isConnecting) && !_isConnected)
                              _buildControlButton(
                                icon: Icons.stop,
                                label: 'Stop',
                                color: Colors.red,
                                onPressed: _stopSearching,
                                large: true,
                              ),
                          ],
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
              color: Colors.white,
              size: large ? 30 : 22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

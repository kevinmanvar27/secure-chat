import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'call_screen.dart';
import 'chat_only_screen.dart';
import 'voice_call_screen.dart';
import 'tutorial_screen.dart';
import 'admin_panel_screen.dart';
import '../services/call_request_service.dart';
import '../services/session_manager.dart';
import '../services/ad_service.dart';
import '../widgets/incoming_call_dialog.dart';
import '../widgets/outgoing_call_dialog.dart';
import '../theme/app_theme.dart';
import 'dart:async';

class HomeTab extends StatefulWidget {
  final String? initialRemoteId; // For deep link - auto-fill remote ID
  
  const HomeTab({super.key, this.initialRemoteId});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with AutomaticKeepAliveClientMixin {
  final SessionManager _sessionManager = SessionManager();
  final AdService _adService = AdService();
  String get myUserId => _sessionManager.userId;
  
  final TextEditingController _remoteIdController = TextEditingController();
  bool _isLoading = false;
  
  final CallRequestService _callRequestService = CallRequestService();
  StreamSubscription? _incomingRequestSubscription;
  bool _isListening = false;

  // Banner Ad
  BannerAd? _bannerAd;
  bool _isBannerAdLoaded = false;

  // Play Store link with deep link support
  static const String playStoreLink = 'https://play.google.com/store/apps/details?id=com.rektech.chatapp';
  static const String appLink = 'https://securechat.app/call/'; // Deep link base

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _listenForIncomingCalls();
    _loadBannerAd();
    _checkDeepLinkPermission();
    
    // If deep link provided initial remote ID, fill it
    if (widget.initialRemoteId != null && widget.initialRemoteId!.isNotEmpty) {
      _remoteIdController.text = widget.initialRemoteId!;
    }
  }

  @override
  void dispose() {
    _remoteIdController.dispose();
    _incomingRequestSubscription?.cancel();
    _callRequestService.dispose();
    _bannerAd?.dispose();
    super.dispose();
  }

  void _loadBannerAd() {
    final bannerAd = _adService.createBannerAd(
      onAdLoaded: () {
        setState(() {
          _isBannerAdLoaded = true;
        });
      },
      onAdFailedToLoad: (error) {
        setState(() {
          _isBannerAdLoaded = false;
        });
      },
    );
    
    if (bannerAd != null) {
      _bannerAd = bannerAd;
      _bannerAd!.load();
    }
  }
  
  void _listenForIncomingCalls() {
    setState(() {
      _isListening = true;
    });
    
    _callRequestService.listenForIncomingRequests(myUserId);
    
    _incomingRequestSubscription?.cancel();
    _incomingRequestSubscription = _callRequestService.incomingRequests.listen(
      (request) {
        _showIncomingCallDialog(request);
      },
      onError: (error) {
        setState(() {
          _isListening = false;
        });
      },
    );
  }

  Future<bool> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    return statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;
  }

  // Store selected call type for use in _joinCall
  CallType _selectedCallType = CallType.video;

  Future<void> _startCall(CallType callType) async {
    try {
      if (_remoteIdController.text.trim().isEmpty) {
        _showSnackBar('Please enter Remote User ID');
        return;
      }
      
      // Store the selected call type
      _selectedCallType = callType;
      
      // Check for admin access
      if (_remoteIdController.text.trim().toLowerCase() == 'googleadsadmin') {
        _showAdminPasswordDialog();
        return;
      }

      if (_remoteIdController.text.trim().toUpperCase() == myUserId) {
        _showSnackBar('You cannot call yourself');
        return;
      }

      setState(() => _isLoading = true);

      bool permissionsGranted = await _requestPermissions();
      
      if (!permissionsGranted) {
        setState(() => _isLoading = false);
        _showSnackBar('Camera and Microphone permissions required');
        return;
      }

      // Check if should show ad for private call
      if (_adService.shouldShowAdForPrivateCall()) {
        await _adService.showInterstitialAd();
      }

      String receiverId = _remoteIdController.text.trim().toUpperCase();
      
      _sessionManager.currentRoomId = await _callRequestService.createCallRoom(myUserId);
      
      _sessionManager.currentRequestId = await _callRequestService.sendCallRequest(
        callerId: myUserId,
        callerName: 'User $myUserId',
        receiverId: receiverId,
        roomId: _sessionManager.currentRoomId!,
        callType: callType,
      );
      
      setState(() => _isLoading = false);
      
      if (mounted) {
        _showOutgoingCallDialog(receiverId);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar('An error occurred: $e');
      }
    }
  }
  
  void _showOutgoingCallDialog(String receiverId) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => OutgoingCallDialog(
        receiverName: 'User $receiverId',
        receiverId: receiverId,
        onCancel: () async {
          // Cancel the call request
          if (_sessionManager.currentRequestId != null) {
            await _callRequestService.cancelCallRequest(_sessionManager.currentRequestId!);
          }
          // Leave and cleanup the room
          if (_sessionManager.currentRoomId != null) {
            await _callRequestService.leaveCallRoom(_sessionManager.currentRoomId!, myUserId);
          }
          // Clear session data
          _sessionManager.clearCallSession();
          // Close dialog
          Navigator.of(context).pop();
        },
      ),
    );
    
    if (_sessionManager.currentRequestId != null) {
      _callRequestService.listenForRequestStatus(_sessionManager.currentRequestId!);
      
      final statusSubscription = _callRequestService.requestStatusUpdates.listen((request) {
        if (request.requestId == _sessionManager.currentRequestId) {
          if (request.status == 'accepted') {
            Navigator.of(context).pop();
            _joinCall(request.roomId, receiverId, isCaller: true);
          } else if (request.status == 'rejected') {
            Navigator.of(context).pop();
            // Cleanup room on rejection
            if (_sessionManager.currentRoomId != null) {
              _callRequestService.leaveCallRoom(_sessionManager.currentRoomId!, myUserId);
            }
            _sessionManager.clearCallSession();
            _showSnackBar('Call rejected by $receiverId');
          } else if (request.status == 'cancelled') {
            Navigator.of(context).pop();
            // Cleanup room on cancellation
            if (_sessionManager.currentRoomId != null) {
              _callRequestService.leaveCallRoom(_sessionManager.currentRoomId!, myUserId);
            }
            _sessionManager.clearCallSession();
          }
        }
      });
      
      Future.delayed(const Duration(seconds: 60), () {
        statusSubscription.cancel();
      });
    }
  }
  
  void _showIncomingCallDialog(CallRequest request) {
    // Listen for request status changes (in case caller cancels)
    _callRequestService.listenForRequestStatus(request.requestId);
    
    StreamSubscription? statusSubscription;
    statusSubscription = _callRequestService.requestStatusUpdates.listen((updatedRequest) {
      if (updatedRequest.requestId == request.requestId) {
        if (updatedRequest.status == 'cancelled') {
          // Caller cancelled the call
          Navigator.of(context).pop();
          statusSubscription?.cancel();
          _showSnackBar('Call cancelled by caller');
        }
      }
    });
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => IncomingCallDialog(
        request: request,
        onAccept: () async {
          statusSubscription?.cancel();
          Navigator.of(context).pop();
          await _callRequestService.acceptCallRequest(request.requestId);
          await _callRequestService.joinCallRoom(request.roomId, myUserId);
          
          bool permissionsGranted = await _requestPermissions();
          if (!permissionsGranted) {
            _showSnackBar('Camera and Microphone permissions required');
            return;
          }
          
          _joinCall(request.roomId, request.callerId, isCaller: false, callType: request.callType);
        },
        onReject: () async {
          statusSubscription?.cancel();
          Navigator.of(context).pop();
          await _callRequestService.rejectCallRequest(request.requestId);
          _showSnackBar('Call rejected');
        },
      ),
    );
  }
  
  void _joinCall(String roomId, String remoteId, {required bool isCaller, CallType? callType}) {
    _sessionManager.currentRoomId = roomId;
    final effectiveCallType = callType ?? _selectedCallType;
    
    // Navigate to appropriate screen based on call type
    Widget targetScreen;
    switch (effectiveCallType) {
      case CallType.chat:
        targetScreen = ChatOnlyScreen(
          myId: myUserId,
          remoteId: remoteId,
          roomId: roomId,
          isCaller: isCaller,
        );
        break;
      case CallType.voice:
        targetScreen = VoiceCallScreen(
          myId: myUserId,
          remoteId: remoteId,
          roomId: roomId,
          isCaller: isCaller,
        );
        break;
      case CallType.video:
        targetScreen = CallScreen(
          myId: myUserId,
          remoteId: remoteId,
          isCaller: isCaller,
          roomId: roomId,
          callType: effectiveCallType,
        );
        break;
    }
    
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => targetScreen),
    ).then((result) {
      if (mounted) {
        if (_sessionManager.currentRoomId != null) {
          _callRequestService.leaveCallRoom(_sessionManager.currentRoomId!, myUserId);
        }
        
        _sessionManager.clearCallSession();
        
        setState(() {
          _remoteIdController.clear();
        });
        
        _showSnackBar('Session ended');
        _listenForIncomingCalls();
      }
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.getPrimaryColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _copyMyId() {
    Clipboard.setData(ClipboardData(text: myUserId));
    _showSnackBar('ID copied!');
  }

  void _shareMyId() {
    final message = '''Hey! Join me on SecureChat for free encrypted video calls.

📱 Download the app:
$playStoreLink

📞 After installing, click to call me:
https://securechat.app/call/$myUserId

🆔 My Code: $myUserId''';
    
    Share.share(message, subject: 'Join me on SecureChat');
  }

  void _openTutorial() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const TutorialScreen(isFirstTime: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      onPressed: _openTutorial,
                      icon: Icon(
                        Icons.help_outline,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      tooltip: 'How it works',
                    ),

                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            'Secure Chat',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.onSurface,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Secure • Encrypted • HD Quality',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 40),

                  ],
                ),

                const SizedBox(height: 32),

                // Your ID Card
                Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.person_outline,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Your ID',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _isListening 
                                    ? AppTheme.getActiveIndicatorColor(context) 
                                    : AppTheme.getPrimaryColor(context),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _isListening ? 'Ready to receive calls' : 'Connecting...',
                              style: TextStyle(
                                fontSize: 10,
                                color: _isListening 
                                    ? AppTheme.getActiveIndicatorColor(context) 
                                    : AppTheme.getPrimaryColor(context),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onLongPress: _copyMyId,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              myUserId,
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 4,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildActionButton(
                              icon: Icons.copy,
                              label: 'Copy',
                              onTap: _copyMyId,
                            ),
                            const SizedBox(width: 16),
                            _buildActionButton(
                              icon: Icons.share,
                              label: 'Share',
                              onTap: _shareMyId,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Remote ID input
                TextField(
                  controller: _remoteIdController,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 3,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter Remote ID',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      letterSpacing: 1,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
                      fontWeight: FontWeight.normal,
                    ),
                    prefixIcon: Icon(
                      Icons.person_search_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    suffixIcon: _remoteIdController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setState(() {
                                _remoteIdController.clear();
                              });
                            },
                          )
                        : null,
                  ),
                  onChanged: (value) {
                    setState(() {});
                  },
                ),

                const SizedBox(height: 24),

                // Call Type Options - 3 buttons
                Row(
                  children: [
                    // Chat Only Button
                    Expanded(
                      child: _buildCallTypeButton(
                        icon: Icons.chat_rounded,
                        label: 'Chat',
                        callType: CallType.chat,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Voice Call Button
                    Expanded(
                      child: _buildCallTypeButton(
                        icon: Icons.phone_rounded,
                        label: 'Voice',
                        callType: CallType.voice,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Video Call Button
                    Expanded(
                      child: _buildCallTypeButton(
                        icon: Icons.videocam_rounded,
                        label: 'Video',
                        callType: CallType.video,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Features
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildFeature(Icons.lock_rounded, 'Encrypted'),
                        _buildFeature(Icons.hd_rounded, 'HD Video'),
                        _buildFeature(Icons.speed_rounded, 'Fast'),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Banner Ad
                if (_isBannerAdLoaded && _bannerAd != null)
                  Container(
                    alignment: Alignment.center,
                    width: _bannerAd!.size.width.toDouble(),
                    height: _bannerAd!.size.height.toDouble(),
                    child: AdWidget(ad: _bannerAd!),
                  ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeature(IconData icon, String text) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildCallTypeButton({
    required IconData icon,
    required String label,
    required CallType callType,
  }) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: _isLoading ? null : () => _startCall(callType),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: _isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  void _showAdminPasswordDialog() {
    final passwordController = TextEditingController();
    final primaryColor = AppTheme.getPrimaryColor(context);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.admin_panel_settings, color: primaryColor),
            const SizedBox(width: 10),
            const Text('Admin Access'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter admin password to continue',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                letterSpacing: 8,
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                hintText: '••••',
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primaryColor, width: 2),
                ),
              ),
              onSubmitted: (value) {
                if (value == '2795') {
                  Navigator.pop(context);
                  _remoteIdController.clear();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
                  );
                } else {
                  Navigator.pop(context);
                  _showSnackBar('Invalid password');
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (passwordController.text == '2795') {
                Navigator.pop(context);
                _remoteIdController.clear();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
                );
              } else {
                Navigator.pop(context);
                _showSnackBar('Invalid password');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: AppTheme.getOnPrimaryColor(context),
            ),
            child: const Text('Enter'),
          ),
        ],
      ),
    );
  }

  /// Check and prompt for deep link permission
  Future<void> _checkDeepLinkPermission() async {
    if (!Platform.isAndroid) return;
    
    // Check if we've already asked
    final prefs = await SharedPreferences.getInstance();
    final hasAsked = prefs.getBool('deep_link_permission_asked') ?? false;
    
    if (!hasAsked) {
      // Wait a bit for the UI to settle
      await Future.delayed(const Duration(seconds: 2));
      
      if (mounted) {
        _showDeepLinkPermissionDialog();
        await prefs.setBool('deep_link_permission_asked', true);
      }
    }
  }

  void _showDeepLinkPermissionDialog() {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.link, color: primaryColor),
            const SizedBox(width: 10),
            const Expanded(child: Text('Enable Direct Links')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'To open call links directly in the app, please enable link handling in settings.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Text(
              'This allows friends to call you directly by clicking your shared link.',
              style: TextStyle(fontSize: 13, color: onSurfaceColor.withOpacity(0.6)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _openAppLinkSettings();
            },
            icon: const Icon(Icons.settings, size: 18),
            label: const Text('Open Settings'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: AppTheme.getOnPrimaryColor(context),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openAppLinkSettings() async {
    if (Platform.isAndroid) {
      try {
        const intent = AndroidIntent(
          action: 'android.settings.APP_OPEN_BY_DEFAULT_SETTINGS',
          data: 'package:com.rektech.chatapp',
        );
        await intent.launch();
      } catch (e) {
        // Fallback to app settings
        try {
          const fallbackIntent = AndroidIntent(
            action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
            data: 'package:com.rektech.chatapp',
          );
          await fallbackIntent.launch();
        } catch (e) {
          _showSnackBar('Please enable links in App Settings manually');
        }
      }
    }
  }
}

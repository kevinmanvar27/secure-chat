import 'package:chatapp/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/webrtc_service.dart';
import '../services/chat_service.dart';
import '../services/call_request_service.dart';
import '../services/ad_service.dart';
import '../widgets/invite_user_dialog.dart';
import '../widgets/join_request_dialog.dart';
import 'dart:async';

/// Video layout types for call screen
enum VideoLayoutType {
  omegle,   // Up-down split (Omegle style)
  whatsapp, // Floating PiP (WhatsApp style)
}

class CallScreen extends StatefulWidget {
  final String myId;
  final String remoteId;
  final bool isCaller;
  final String? roomId; // Optional room ID for multi-user calls
  final bool isRandomCall; // Whether this is a random chat call

  const CallScreen({
    super.key,
    required this.myId,
    required this.remoteId,
    this.isCaller = true,
    this.roomId,
    this.isRandomCall = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with TickerProviderStateMixin {
  final WebRTCService _webrtcService = WebRTCService();
  final ChatService _chatService = ChatService();
  final CallRequestService _callRequestService = CallRequestService();
  final AdService _adService = AdService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _isMultiUserCall = false;
  Map<String, RTCVideoRenderer> _peerRenderers = {};
  List<String> _roomParticipants = [];
  StreamSubscription? _participantsSubscription;

  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  List<ChatMessage> _messages = [];
  bool _isChatVisible = false;
  int _unreadCount = 0;

  Offset _floatingVideoPosition = const Offset(20, 100);
  final double _floatingVideoWidth = 120;
  final double _floatingVideoHeight = 180;

  bool _isCameraOn = true;
  bool _isMicOn = false; // Default muted for private calls
  bool _isCallActive = false;
  String _connectionStatus = 'Initializing...';

  // Track front/back camera for mirror
  bool _isFrontCamera = true;

  // Auto-hide UI
  bool _isUIVisible = true;
  Timer? _uiHideTimer;
  static const Duration _uiHideDelay = Duration(seconds: 4);

  // Video layout preference
  VideoLayoutType _videoLayout = VideoLayoutType.whatsapp;
  static const String _layoutPrefKey = 'video_layout_preference';

  late AnimationController _pulseController;
  late AnimationController _fadeController;
  late AnimationController _chatSlideController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _chatSlideAnimation;

  Timer? _callDurationTimer;
  int _callDurationSeconds = 0;
  StreamSubscription? _chatSubscription;
  StreamSubscription? _localStreamSubscription;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _disconnectSubscription;

  @override
  void initState() {
    super.initState();

    // Keep screen awake during call
    WakelockPlus.enable();
    
    // Load saved layout preference
    _loadLayoutPreference();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _chatSlideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeIn));

    _chatSlideAnimation =
        Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _chatSlideController,
            curve: Curves.easeInOut,
          ),
        );

    _fadeController.forward();

    _webrtcService.remoteDisconnect.listen((disconnected) {
      if (disconnected && mounted) {
        _showDisconnectDialog();
      }
    });

    if (widget.roomId != null) {
      _initializeRoomParticipantsAndCall();
    } else {
      _isMultiUserCall = false;
      _initializeCall();
      _initializeChat();
    }

    _initializeJoinRequestListener();
    _startUIAutoHideTimer();
  }
  
  /// Load saved layout preference from SharedPreferences
  Future<void> _loadLayoutPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLayout = prefs.getString(_layoutPrefKey);
    if (savedLayout != null && mounted) {
      setState(() {
        _videoLayout = savedLayout == 'omegle' 
            ? VideoLayoutType.omegle 
            : VideoLayoutType.whatsapp;
      });
    }
  }
  
  /// Save layout preference to SharedPreferences
  Future<void> _saveLayoutPreference(VideoLayoutType layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_layoutPrefKey, layout == VideoLayoutType.omegle ? 'omegle' : 'whatsapp');
  }
  
  /// Toggle between video layouts
  void _toggleVideoLayout() {
    setState(() {
      _videoLayout = _videoLayout == VideoLayoutType.whatsapp 
          ? VideoLayoutType.omegle 
          : VideoLayoutType.whatsapp;
    });
    _saveLayoutPreference(_videoLayout);
    _startUIAutoHideTimer();
  }

  void _startUIAutoHideTimer() {
    _uiHideTimer?.cancel();
    if (_isCallActive && !_isChatVisible) {
      _uiHideTimer = Timer(_uiHideDelay, () {
        if (mounted) {
          setState(() {
            _isUIVisible = false;
          });
        }
      });
    }
  }

  Future<void> _initializeRoomParticipantsAndCall() async {
    final participants = await _callRequestService.getRoomParticipantsOnce(
      widget.roomId!,
    );

    if (mounted) {
      setState(() {
        _roomParticipants = participants;
        _isMultiUserCall = _roomParticipants.length >= 3;
      });

      await _initializeCall();
      _initializeChat();

      _participantsSubscription = _callRequestService
          .getRoomParticipants(widget.roomId!)
          .listen((participants) {
            if (mounted) {
              setState(() {
                _roomParticipants = participants;
              });
              /*if (_isMultiUserCall) {
            for (var participantId in participants) {
              if (participantId != widget.myId && 
                  !_peerRenderers.containsKey(participantId)) {
                _multiPeerService.connectToPeer(widget.roomId!, widget.myId, participantId);
              }
            }
          }*/
            }
          });
    }
  }

  void _initializeChat() {
    if (_isMultiUserCall) {
      _chatService.startListeningToRoom(widget.roomId!);

      _chatSubscription = _chatService.roomMessages.listen((roomMessages) {
        if (mounted) {
          List<ChatMessage> messages = roomMessages.map((rm) {
            return ChatMessage(
              id: rm.id,
              senderId: rm.senderId,
              receiverId: '', // Not used in room chat
              message: '${rm.senderName}: ${rm.message}',
              timestamp: rm.timestamp,
              isRead: true,
            );
          }).toList();

          setState(() {
            if (!_isChatVisible) {
              int newMessages = messages.length - _messages.length;
              if (newMessages > 0) {
                _unreadCount += newMessages;
              }
            }
            _messages = messages;
          });

          if (_isChatVisible) {
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_chatScrollController.hasClients) {
                _chatScrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            });
          }
        }
      });
    } else {
      _chatService.startListening(widget.myId, widget.remoteId);

      _chatSubscription = _chatService.messages.listen((messages) {
        if (mounted) {
          setState(() {
            if (!_isChatVisible) {
              int newMessages = messages.length - _messages.length;
              if (newMessages > 0) {
                _unreadCount += newMessages;
              }
            }
            _messages = messages;
          });

          if (_isChatVisible) {
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_chatScrollController.hasClients) {
                _chatScrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            });
          }
        }
      });
    }
  }

  void _initializeJoinRequestListener() {
    if (widget.roomId == null) return;

    _callRequestService.listenForJoinRequests(widget.roomId!);

    _callRequestService.joinRequests.listen((joinRequest) {
      if (mounted) {
        _showJoinRequestDialog(joinRequest);
      }
    });
  }

  void _showJoinRequestDialog(JoinRequest joinRequest) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => JoinRequestDialog(
        request: joinRequest,
        onAccept: () async {
          Navigator.pop(context);
          await _callRequestService.acceptJoinRequest(
            joinRequest.requestId,
            joinRequest.roomId,
            joinRequest.userId,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${joinRequest.userName} joined the call'),
                backgroundColor: AppTheme.getSuccessColor(context),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        },
        onReject: () async {
          Navigator.pop(context);
          await _callRequestService.rejectJoinRequest(joinRequest.requestId);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Rejected ${joinRequest.userName}\'s request'),
                backgroundColor: AppTheme.getPrimaryColor(context),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        },
      ),
    );
  }

  void _toggleChat() {
    setState(() {
      _isChatVisible = !_isChatVisible;
      if (_isChatVisible) {
        _unreadCount = 0; // Reset unread count
        _chatSlideController.forward();
        _chatService.markMessagesAsRead(widget.myId, widget.remoteId);
        // Show overlay UI when chat opens
        _isUIVisible = true;
        _uiHideTimer?.cancel(); // Don't hide UI while chat is open
      } else {
        _chatSlideController.reverse();
        // Show overlay UI when chat closes and start auto-hide timer
        _isUIVisible = true;
        _startUIAutoHideTimer();
      }
    });
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final message = _messageController.text.trim();
    _messageController.clear();

    try {
      if (_isMultiUserCall && widget.roomId != null) {
        await _chatService.sendMessageToRoom(
          widget.roomId!,
          widget.myId,
          'User ${widget.myId.substring(0, 6)}', // You can pass actual user name
          message,
        );
      } else {
        await _chatService.sendMessage(widget.myId, widget.remoteId, message);
      }

      Future.delayed(const Duration(milliseconds: 100), () {
        if (_chatScrollController.hasClients) {
          _chatScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to send message: $e')));
      }
    }
  }

  Future<void> _initializeCall() async {
    try {
      if (_isMultiUserCall) {
      } else {
        String actualRemoteId = widget.remoteId;
        if (widget.roomId != null && _roomParticipants.length == 2) {
          actualRemoteId = _roomParticipants.firstWhere(
            (id) => id != widget.myId,
            orElse: () => widget.remoteId,
          );
        }
        await _initializeOneToOneCallWithRemote(actualRemoteId);
      }
    } catch (e) {
      _showErrorAndExit('Call initialization failed: $e');
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppTheme.getPrimaryColor(context),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _initializeOneToOneCall() async {
    await _initializeOneToOneCallWithRemote(widget.remoteId);
  }

  Future<void> _initializeOneToOneCallWithRemote(String remoteId) async {
    _updateStatus('Initializing renderers...');

    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _updateStatus('Getting camera and microphone...');

    // Clear any existing peer connection but keep local stream if valid
    await _webrtcService.resetConnectionWithoutStreamReinit();
    
    // Initialize local stream (will reuse if already valid)
    await _webrtcService.initializeLocalStream();

    // Mute mic by default for private calls (not random calls)
    if (!widget.isRandomCall) {
      _webrtcService.setMicEnabled(false); // Mute directly
      _isMicOn = false;
    } else {
      _webrtcService.setMicEnabled(true); // Unmute for random calls
      _isMicOn = true;
    }

    // Set local renderer with current stream
    if (_webrtcService.currentLocalStream != null) {
      setState(() {
        _localRenderer.srcObject = _webrtcService.currentLocalStream;
      });
    }

    // Setup stream listeners BEFORE initiating WebRTC connection
    _setupStreamListeners();

    // Use consistent room ID - always use the provided roomId
    // If not provided, create a consistent format (sorted IDs to ensure same room for both peers)
    final String effectiveRoomId =
        widget.roomId ?? ([widget.myId, remoteId]..sort()).join('_');

    // Ensure local stream is ready before creating offer/handling offer
    _updateStatus('Preparing connection...');
    await _webrtcService.ensureLocalStreamReady();
    
    // Update local renderer again in case stream was reinitialized
    if (_webrtcService.currentLocalStream != null) {
      _localRenderer.srcObject = _webrtcService.currentLocalStream;
    }
    
    // Enable speakerphone for video calls by default
    await _webrtcService.enableSpeakerphone(true);

    if (widget.isCaller) {
      _updateStatus('Calling...');
      await _webrtcService.createOffer(effectiveRoomId, remoteUserId: remoteId);
    } else {
      _updateStatus('Connecting...');
      await _webrtcService.handleOffer(effectiveRoomId, remoteId);
    }
  }
  
  /// Setup stream listeners - call this BEFORE starting WebRTC connection
  void _setupStreamListeners() {
    debugPrint('🎧 CallScreen: Setting up stream listeners');
    
    // Listen for local stream changes
    _localStreamSubscription?.cancel();
    _localStreamSubscription = _webrtcService.localStream.listen((stream) {
      debugPrint('📹 CallScreen: Local stream updated: ${stream.getTracks().length} tracks');
      if (mounted) {
        setState(() {
          _localRenderer.srcObject = stream;
        });
      }
    });

    // Listen for remote stream
    _remoteStreamSubscription?.cancel();
    _remoteStreamSubscription = _webrtcService.remoteStream.listen((stream) {
      _handleRemoteStream(stream);
    });

    // Listen for disconnect
    _disconnectSubscription?.cancel();
    _disconnectSubscription = _webrtcService.remoteDisconnect.listen((disconnected) {
      debugPrint('📹 CallScreen: Remote disconnect signal: $disconnected');
      if (disconnected && mounted) {
        _showSnackBar('Call ended');
        Navigator.of(context).pop();
      }
    });
    
    // Check if there's already a remote stream (in case we missed the event)
    if (_webrtcService.currentRemoteStream != null) {
      debugPrint('📹 CallScreen: Found existing remote stream, using it');
      _handleRemoteStream(_webrtcService.currentRemoteStream!);
    }
    
    debugPrint('🎧 CallScreen: Stream listeners setup complete');
  }
  
  /// Handle incoming remote stream
  void _handleRemoteStream(MediaStream stream) {
    debugPrint('📹 CallScreen: _handleRemoteStream called');
    debugPrint('📹 CallScreen: Remote stream received! tracks=${stream.getTracks().length}');
    debugPrint('📹 Video tracks: ${stream.getVideoTracks().length}');
    debugPrint('📹 Audio tracks: ${stream.getAudioTracks().length}');
    
    if (stream.getTracks().isEmpty) {
      debugPrint('⚠️ CallScreen: Remote stream has no tracks!');
      return;
    }
    
    // Ensure audio tracks are enabled
    for (var track in stream.getAudioTracks()) {
      track.enabled = true;
      debugPrint('📹 CallScreen: Audio track enabled: ${track.enabled}, id: ${track.id}');
    }
    
    // Ensure video tracks are enabled
    for (var track in stream.getVideoTracks()) {
      track.enabled = true;
      debugPrint('📹 CallScreen: Video track enabled: ${track.enabled}, id: ${track.id}');
    }
    
    if (mounted) {
      debugPrint('✅ CallScreen: Setting remote stream to renderer');
      // IMPORTANT: Set srcObject INSIDE setState like random_tab does
      setState(() {
        _remoteRenderer.srcObject = stream;
        _isCallActive = true;
        _connectionStatus = 'Connected!';
      });
      debugPrint('✅ CallScreen: _isCallActive = $_isCallActive');
      if (_callDurationTimer == null) {
        _startCallDurationTimer();
      }
    } else {
      debugPrint('⚠️ CallScreen: Widget not mounted, cannot set remote stream');
    }
  }

  /*Future<void> _initializeMultiUserCall() async {
    _updateStatus('Initializing multi-user call...');

    await _localRenderer.initialize();

    _updateStatus('Getting camera and microphone...');

    await _multiPeerService.initializeLocalStream();

    if (_multiPeerService.currentLocalStream != null) {
      _localRenderer.srcObject = _multiPeerService.currentLocalStream;
      setState(() {});
    }

    _multiPeerService.localStream.listen((stream) {
      _localRenderer.srcObject = stream;
      setState(() {});
    });

    _multiPeerService.remoteStreams.listen((streams) async {
      for (var entry in streams.entries) {
        final peerId = entry.key;
        final stream = entry.value;
        
        if (!_peerRenderers.containsKey(peerId)) {
          final renderer = RTCVideoRenderer();
          await renderer.initialize();
          _peerRenderers[peerId] = renderer;
        }
        
        _peerRenderers[peerId]!.srcObject = stream;
      }
      
      final disconnectedPeers = _peerRenderers.keys
          .where((peerId) => !streams.containsKey(peerId))
          .toList();
      
      for (var peerId in disconnectedPeers) {
        await _peerRenderers[peerId]?.dispose();
        _peerRenderers.remove(peerId);
      }
      
      setState(() {
        _isCallActive = streams.isNotEmpty;
        _connectionStatus = streams.isEmpty 
            ? 'Waiting for participants...' 
            : 'Connected to ${streams.length} peer(s)';
      });
      
      if (streams.isNotEmpty && _callDurationTimer == null) {
        _startCallDurationTimer();
      }
    });

    _multiPeerService.peerDisconnect.listen((peerId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Peer $peerId left the call'),
            backgroundColor: AppTheme.getPrimaryColor(context),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });

    _multiPeerService.listenForOffers(widget.roomId!, widget.myId);

    _updateStatus('Connecting to participants...');
    for (var participantId in _roomParticipants) {
      if (participantId != widget.myId) {
        await _multiPeerService.connectToPeer(widget.roomId!, widget.myId, participantId);
      }
    }
  }*/

  void _startCallDurationTimer() {
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDurationSeconds++;
        });
      }
    });
  }

  String _formatDuration(int seconds) {
    int hours = seconds ~/ 3600;
    int minutes = (seconds % 3600) ~/ 60;
    int secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _updateStatus(String status) {
    if (mounted) {
      setState(() {
        _connectionStatus = status;
      });
    }
  }

  void _showErrorAndExit(String message) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.getDialogBackgroundColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Error', style: TextStyle(color: AppTheme.getOnSurfaceColor(context))),
        content: Text(message, style: TextStyle(color: AppTheme.getOnSurfaceColor(context).withOpacity(0.7))),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _endCall();
            },
            child: Text(
              'OK',
              style: TextStyle(color: AppTheme.getPrimaryColor(context)),
            ),
          ),
        ],
      ),
    );
  }

  void _showDisconnectDialog() {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.getDialogBackgroundColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.call_end, color: AppTheme.getErrorColor(context)),
            const SizedBox(width: 10),
            Text('Call Ended', style: TextStyle(color: AppTheme.getOnSurfaceColor(context))),
          ],
        ),
        content: Text(
          'Remote user has disconnected.\nReturning to home screen...',
          style: TextStyle(color: AppTheme.getOnSurfaceColor(context).withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // Close dialog
              await _endCall(); // End call and refresh
            },
            child: Text(
              'OK',
              style: TextStyle(color: AppTheme.getPrimaryColor(context)),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleCamera() {
    setState(() {
      _isCameraOn = !_isCameraOn;
      if (_isMultiUserCall) {
      } else {
        _webrtcService.toggleCamera();
      }
    });
  }

  void _toggleMicrophone() {
    setState(() {
      _isMicOn = !_isMicOn;
      if (_isMultiUserCall) {
      } else {
        _webrtcService.toggleMicrophone();
      }
    });
  }

  Future<void> _switchCamera() async {
    if (_isMultiUserCall) {
    } else {
      // First toggle the mirror state, then switch camera
      // This ensures UI updates immediately with correct mirror
      setState(() {
        _isFrontCamera = !_isFrontCamera;
      });
      await _webrtcService.switchCamera();
    }
  }

  // Speaker toggle for Bluetooth/Speaker audio routing
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

  void _showParticipantsList() {
    if (widget.roomId == null || _roomParticipants.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.getDialogBackgroundColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.people, color: AppTheme.getPrimaryColor(context)),
            const SizedBox(width: 10),
            Text('Participants', style: TextStyle(color: AppTheme.getOnSurfaceColor(context))),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _roomParticipants.length,
            itemBuilder: (context, index) {
              final participantId = _roomParticipants[index];
              final isMe = participantId == widget.myId;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isMe
                      ? AppTheme.getPrimaryColor(context).withOpacity(0.2)
                      : AppTheme.getOnSurfaceColor(context).withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isMe
                        ? AppTheme.getPrimaryColor(context).withOpacity(0.5)
                        : AppTheme.getOnSurfaceColor(context).withOpacity(0.1),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: isMe
                          ? AppTheme.getPrimaryColor(context)
                          : AppTheme.getSecondaryColor(context),
                      child: Text(
                        participantId.substring(0, 1).toUpperCase(),
                        style: TextStyle(
                          color: AppTheme.getOnPrimaryColor(context),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isMe ? 'You' : 'User $participantId',
                            style: TextStyle(
                              color: AppTheme.getOnSurfaceColor(context),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            participantId,
                            style: TextStyle(
                              color: AppTheme.getOnSurfaceColor(context).withOpacity(0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isMe)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.getPrimaryColor(context).withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'YOU',
                          style: TextStyle(
                            color: AppTheme.getOnSurfaceColor(context),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(color: AppTheme.getPrimaryColor(context)),
            ),
          ),
        ],
      ),
    );
  }

  void _showInviteUserDialog() {
    if (widget.roomId == null) return;

    showDialog(
      context: context,
      builder: (context) => InviteUserDialog(
        roomId: widget.roomId!,
        currentUserId: widget.myId,
        onInvite: (userId) async {
          try {
            await _callRequestService.sendCallRequest(
              callerId: widget.myId,
              callerName: 'User ${widget.myId.substring(0, 6)}',
              receiverId: userId,
              roomId: widget.roomId!,
            );

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Invitation sent to $userId'),
                  backgroundColor: AppTheme.getSuccessColor(context),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to send invitation: $e'),
                  backgroundColor: AppTheme.getErrorColor(context),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _endCall() async {
    // First pop the screen to avoid black screen
    if (mounted) {
      Navigator.pop(context, true);
    }
    
    try {
      _callDurationTimer?.cancel();
      _chatSubscription?.cancel();
      _participantsSubscription?.cancel();

      if (widget.roomId != null) {
        await _callRequestService.leaveCallRoom(widget.roomId!, widget.myId);
      }

      if (_isMultiUserCall && widget.roomId != null) {
        for (var renderer in _peerRenderers.values) {
          await renderer.dispose();
        }
        _peerRenderers.clear();
      } else {
        await _chatService.clearChatHistory(widget.myId, widget.remoteId);
        // Use roomId for endCall, not myId
        final effectiveRoomId =
            widget.roomId ?? ([widget.myId, widget.remoteId]..sort()).join('_');
        await _webrtcService.endCall(effectiveRoomId);
        // Don't dispose - WebRTCService is singleton, just reset connection
      }

      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
      
      // Show interstitial ad when call ends (for private calls only)
      if (!widget.isRandomCall) {
        _adService.showInterstitialAd();
      }
    } catch (e) {
      // Cleanup errors are not critical
    }
  }

  /// Build multi-peer video grid for group calls
  Widget _buildMultiPeerVideoGrid() {
    final peerCount = _peerRenderers.length;

    if (peerCount == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 80,
              color: AppTheme.getOnSurfaceColor(context).withOpacity(0.3),
            ),
            const SizedBox(height: 20),
            Text(
              'Waiting for participants...',
              style: TextStyle(
                color: AppTheme.getOnSurfaceColor(context).withOpacity(0.7),
                fontSize: 18,
              ),
            ),
          ],
        ),
      );
    }

    if (peerCount == 1) {
      final renderer = _peerRenderers.values.first;
      return RTCVideoView(
        renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        mirror: false,
        filterQuality: FilterQuality.medium,
      );
    }

    if (peerCount == 2) {
      final renderers = _peerRenderers.values.toList();
      return Column(
        children: [
          Expanded(
            child: _buildVideoTile(
              renderers[0],
              _peerRenderers.keys.toList()[0],
            ),
          ),
          Expanded(
            child: _buildVideoTile(
              renderers[1],
              _peerRenderers.keys.toList()[1],
            ),
          ),
        ],
      );
    }

    if (peerCount <= 4) {
      final renderers = _peerRenderers.values.toList();
      final peerIds = _peerRenderers.keys.toList();
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                if (peerCount > 0)
                  Expanded(child: _buildVideoTile(renderers[0], peerIds[0])),
                if (peerCount > 1)
                  Expanded(child: _buildVideoTile(renderers[1], peerIds[1])),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                if (peerCount > 2)
                  Expanded(child: _buildVideoTile(renderers[2], peerIds[2])),
                if (peerCount > 3)
                  Expanded(child: _buildVideoTile(renderers[3], peerIds[3])),
              ],
            ),
          ),
        ],
      );
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
      ),
      itemCount: peerCount,
      itemBuilder: (context, index) {
        final peerId = _peerRenderers.keys.toList()[index];
        final renderer = _peerRenderers[peerId]!;
        return _buildVideoTile(renderer, peerId);
      },
    );
  }

  /// Build individual video tile with peer ID label
  Widget _buildVideoTile(RTCVideoRenderer renderer, String peerId) {
    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppTheme.getOverlayColor(context),
        border: Border.all(
          color: AppTheme.getPrimaryColor(context).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Stack(
        children: [
          RTCVideoView(
            renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            mirror: false,
            filterQuality: FilterQuality.medium,
          ),
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.getOverlayColor(context).withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppTheme.getPrimaryColor(context).withOpacity(0.5),
                  width: 1,
                ),
              ),
              child: Text(
                peerId.substring(0, 8), // Show first 8 chars of peer ID
                style: TextStyle(
                  color: AppTheme.getOnSurfaceColor(context),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Disable wake lock when leaving call screen
    WakelockPlus.disable();

    try {
      _callDurationTimer?.cancel();
      _localStreamSubscription?.cancel();
      _remoteStreamSubscription?.cancel();
      _disconnectSubscription?.cancel();
      _localRenderer.dispose();
      _remoteRenderer.dispose();

      for (var renderer in _peerRenderers.values) {
        renderer.dispose();
      }
      _peerRenderers.clear();

      _pulseController.dispose();
      _fadeController.dispose();
      _chatSlideController.dispose();
      _uiHideTimer?.cancel();
      _chatSubscription?.cancel();
      _participantsSubscription?.cancel();
      _callRequestService.dispose();
      
      // IMPORTANT: Reset WebRTC connection to ensure clean state for next call
      // This prevents issues when switching to random tab after a private call
      final effectiveRoomId = widget.roomId ?? ([widget.myId, widget.remoteId]..sort()).join('_');
      _webrtcService.endCall(effectiveRoomId);
    } catch (e) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final overlayColor = AppTheme.getOverlayColor(context);
    
    return WillPopScope(
      onWillPop: () async {
        return false;
      },
      child: Scaffold(
        backgroundColor: overlayColor,
        body: GestureDetector(
          onTap: () {
            // Only toggle UI when call is active
            if (_isCallActive && !_isChatVisible) {
              setState(() {
                _isUIVisible = !_isUIVisible;
              });
              if (_isUIVisible) {
                _startUIAutoHideTimer();
              }
            }
          },
          child: SafeArea(
            child: Stack(
              children: [
                // Video content based on layout type
                if (_isCallActive && !_isChatVisible)
                  _videoLayout == VideoLayoutType.omegle
                      ? _buildOmegleLayout()
                      : _buildWhatsAppLayout()
                else
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: AppTheme.getCallBackgroundGradient(context),
                        ),
                      ),
                      child: FadeTransition(
                        opacity: _fadeAnimation,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ScaleTransition(
                              scale: _pulseAnimation,
                              child: Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: primaryColor,
                                ),
                                child: Icon(
                                  Icons.video_call_rounded,
                                  size: 60,
                                  color: AppTheme.getOnPrimaryColor(context),
                                ),
                              ),
                            ),
                            const SizedBox(height: 40),
                            CircularProgressIndicator(
                              color: primaryColor,
                              strokeWidth: 3,
                            ),
                            const SizedBox(height: 30),
                            Text(
                              _connectionStatus,
                              style: TextStyle(
                                color: onSurfaceColor,
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: onSurfaceColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: onSurfaceColor.withOpacity(0.2),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                widget.isCaller
                                    ? '📤 Initiating Call'
                                    : '📥 Receiving Call',
                                style: TextStyle(
                                  color: primaryColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Top gradient overlay (only for WhatsApp layout)
                if (_isCallActive && !_isChatVisible && _videoLayout == VideoLayoutType.whatsapp)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 200,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            overlayColor.withOpacity(0.7),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),

                // Bottom gradient overlay (only for WhatsApp layout)
                if (_isCallActive && !_isChatVisible && _videoLayout == VideoLayoutType.whatsapp)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 250,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            overlayColor.withOpacity(0.8),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),

                // Local video preview for WhatsApp layout (floating PiP)
                if (!_isChatVisible && _videoLayout == VideoLayoutType.whatsapp)
                  Positioned(
                    top: 60,
                    right: 20,
                    child: GestureDetector(
                      onTap: _switchCamera,
                      child: Container(
                        width: 110,
                        height: 160,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: LinearGradient(
                            colors: AppTheme.getLocalVideoBorderGradient(context),
                          ),
                          border: Border.all(
                            color: AppTheme.getLocalVideoBorderColor(context),
                            width: 2,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            children: [
                              RTCVideoView(
                                _localRenderer,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitCover,
                                mirror: true, // Always mirror local video (like looking in a real mirror)
                                filterQuality: FilterQuality.medium,
                              ),
                              if (!_isCameraOn)
                                Container(
                                  color: overlayColor,
                                  child: Center(
                                    child: Icon(
                                      Icons.videocam_off_rounded,
                                      color: onSurfaceColor,
                                      size: 32,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                if (!_isChatVisible && _isUIVisible)
                  Positioned(
                    top: 20,
                    left: 20,
                    right: _videoLayout == VideoLayoutType.whatsapp ? 150 : 20, // Leave space for local video in WhatsApp mode
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: overlayColor.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: onSurfaceColor.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _isCallActive
                                      ? AppTheme.getActiveIndicatorColor(context)
                                      : AppTheme.getConnectingIndicatorColor(context),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _isCallActive
                                      ? _formatDuration(_callDurationSeconds)
                                      : 'Connecting...',
                                  style: TextStyle(
                                    color: onSurfaceColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'ID: ${widget.remoteId}',
                                  style: TextStyle(
                                    color: onSurfaceColor.withOpacity(0.7),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              if (widget.remoteId != null) ...[
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(text: widget.remoteId!),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Text(
                                          'Room ID copied to clipboard',
                                        ),
                                        duration: const Duration(seconds: 2),
                                        behavior: SnackBarBehavior.floating,
                                        backgroundColor: AppTheme.getSuccessColor(context),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: onSurfaceColor.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Icon(
                                      Icons.copy,
                                      size: 12,
                                      color: onSurfaceColor.withOpacity(0.9),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                // Chat button
                if (_isUIVisible)
                  Positioned(
                    bottom: 140,
                    right: 20,
                    child: GestureDetector(
                      onTap: _toggleChat,
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: AppTheme.getChatButtonGradient(context),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.getChatButtonShadowColor(context),
                              blurRadius: 15,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Stack(
                          children: [
                            Center(
                              child: Icon(
                                _isChatVisible
                                    ? Icons.close
                                    : Icons.chat_bubble_rounded,
                                color: AppTheme.getOnPrimaryColor(context),
                                size: 28,
                              ),
                            ),
                            if (_unreadCount > 0 && !_isChatVisible)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.getErrorColor(context),
                                    shape: BoxShape.circle,
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 20,
                                    minHeight: 20,
                                  ),
                                  child: Text(
                                    _unreadCount > 9 ? '9+' : '$_unreadCount',
                                    style: TextStyle(
                                      color: AppTheme.getOnPrimaryColor(context),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (_isChatVisible && _isUIVisible)
                  Positioned.fill(
                    child: SlideTransition(
                      position: _chatSlideAnimation,
                      child: _buildChatPanel(),
                    ),
                  ),

                if (_isChatVisible && _isCallActive && _isUIVisible)
                  Positioned(
                    left: _floatingVideoPosition.dx,
                    top: _floatingVideoPosition.dy,
                    child: GestureDetector(
                      onPanUpdate: (details) {
                        setState(() {
                          _floatingVideoPosition = Offset(
                            (_floatingVideoPosition.dx + details.delta.dx)
                                .clamp(
                                  0.0,
                                  MediaQuery.of(context).size.width -
                                      _floatingVideoWidth,
                                ),
                            (_floatingVideoPosition.dy + details.delta.dy)
                                .clamp(
                                  0.0,
                                  MediaQuery.of(context).size.height -
                                      _floatingVideoHeight,
                                ),
                          );
                        });
                      },
                      onTap: () {
                        _toggleChat();
                      },
                      child: _buildFloatingVideoWindow(),
                    ),
                  ),

                if (!_isChatVisible && _isUIVisible)
                  Positioned(
                    bottom: 50,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildPremiumControlButton(
                            icon: _isCameraOn
                                ? Icons.videocam_rounded
                                : Icons.videocam_off_rounded,
                            onPressed: _toggleCamera,
                            isActive: _isCameraOn,
                            label: 'Camera',
                          ),

                          _buildPremiumControlButton(
                            icon: _isMicOn
                                ? Icons.mic_rounded
                                : Icons.mic_off_rounded,
                            onPressed: _toggleMicrophone,
                            isActive: _isMicOn,
                            label: 'Mic',
                          ),

                          // Speaker toggle button
                          _buildPremiumControlButton(
                            icon: _isSpeakerOn
                                ? Icons.volume_up_rounded
                                : Icons.volume_down_rounded,
                            onPressed: _toggleSpeaker,
                            isActive: _isSpeakerOn,
                            label: 'Speaker',
                          ),

                          _buildPremiumControlButton(
                            icon: Icons.flip_camera_ios_rounded,
                            onPressed: _switchCamera,
                            isActive: true,
                            label: 'Flip',
                          ),
                          
                          // Layout toggle button (only when connected)
                          if (_isCallActive)
                            _buildLayoutToggleButton(),

                          _buildEndCallButton(),

                          // Next button for random calls
                          if (widget.isRandomCall) _buildNextButton(),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  /// Build Omegle-style layout (split screen: remote on top, local on bottom)
  Widget _buildOmegleLayout() {
    final overlayColor = AppTheme.getOverlayColor(context);
    
    return Positioned.fill(
      child: Column(
        children: [
          // Remote video (top half)
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: AppTheme.getPrimaryColor(context).withOpacity(0.3),
                    width: 2,
                  ),
                ),
              ),
              child: _isMultiUserCall && _peerRenderers.isNotEmpty
                  ? _buildMultiPeerVideoGrid()
                  : RTCVideoView(
                      _remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      mirror: false,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
          // Local video (bottom half)
          Expanded(
            child: Stack(
              children: [
                RTCVideoView(
                  _localRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: true,
                  filterQuality: FilterQuality.medium,
                ),
                if (!_isCameraOn)
                  Container(
                    color: overlayColor,
                    child: Center(
                      child: Icon(
                        Icons.videocam_off_rounded,
                        color: AppTheme.getOnSurfaceColor(context),
                        size: 48,
                      ),
                    ),
                  ),
                // "You" label
                Positioned(
                  bottom: 80,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: overlayColor.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'You',
                      style: TextStyle(
                        color: AppTheme.getOnSurfaceColor(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  /// Build WhatsApp-style layout (full screen remote with floating local PiP)
  Widget _buildWhatsAppLayout() {
    return Positioned.fill(
      child: _isMultiUserCall && _peerRenderers.isNotEmpty
          ? _buildMultiPeerVideoGrid()
          : RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: false,
              filterQuality: FilterQuality.medium,
            ),
    );
  }
  
  /// Build layout toggle button
  Widget _buildLayoutToggleButton() {
    final isOmegle = _videoLayout == VideoLayoutType.omegle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: AppTheme.getPrimaryGradient(context),
            ),
            border: Border.all(
              color: AppTheme.getPrimaryColor(context).withOpacity(0.5),
              width: 2,
            ),
          ),
          child: IconButton(
            icon: Icon(
              isOmegle ? Icons.picture_in_picture : Icons.view_agenda,
              size: 22,
            ),
            color: AppTheme.getOnPrimaryColor(context),
            onPressed: _toggleVideoLayout,
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          isOmegle ? 'PiP' : 'Split',
          style: TextStyle(
            color: AppTheme.getOnSurfaceColor(context).withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildPremiumControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required bool isActive,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: isActive
                ? LinearGradient(
                    colors: AppTheme.getControlButtonActiveGradient(context),
                  )
                : LinearGradient(
                    colors: AppTheme.getControlButtonInactiveGradient(context),
                  ),
            border: Border.all(
              color: isActive
                  ? AppTheme.getOnSurfaceColor(context).withOpacity(0.3)
                  : AppTheme.getErrorColor(context).withOpacity(0.5),
              width: 2,
            ),
          ),
          child: IconButton(
            icon: Icon(icon, size: 22),
            color: AppTheme.getOnSurfaceColor(context),
            onPressed: onPressed,
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: AppTheme.getOnSurfaceColor(context).withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildEndCallButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: AppTheme.getEndCallGradient(context),
            ),
          ),
          child: IconButton(
            icon: const Icon(Icons.call_end_rounded, size: 35),
            color: AppTheme.getOnErrorColor(context),
            onPressed: _endCall,
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'End',
          style: TextStyle(
            color: AppTheme.getOnSurfaceColor(context).withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildNextButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: AppTheme.getNextButtonGradient(context),
            ),
          ),
          child: IconButton(
            icon: const Icon(Icons.skip_next_rounded, size: 24),
            color: AppTheme.getOnPrimaryColor(context),
            onPressed: _findNextRandomUser,
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Next',
          style: TextStyle(
            color: AppTheme.getOnSurfaceColor(context).withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Future<void> _findNextRandomUser() async {
    // End current call and signal to find next random user
    try {
      _callDurationTimer?.cancel();
      _chatSubscription?.cancel();
      _participantsSubscription?.cancel();

      if (widget.roomId != null) {
        await _callRequestService.leaveCallRoom(widget.roomId!, widget.myId);
      }

      await _chatService.clearChatHistory(widget.myId, widget.remoteId);
      final effectiveRoomId =
          widget.roomId ?? ([widget.myId, widget.remoteId]..sort()).join('_');
      await _webrtcService.endCall(effectiveRoomId);

      await _localRenderer.dispose();
      await _remoteRenderer.dispose();

      if (mounted) {
        Navigator.pop(context, 'find_next');
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context, 'find_next');
      }
    }
  }

  Widget _buildFloatingVideoWindow() {
    final overlayColor = AppTheme.getOverlayColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    
    return Container(
      width: _floatingVideoWidth,
      height: _floatingVideoHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.getPrimaryColor(context).withOpacity(0.8),
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: overlayColor.withOpacity(0.5),
            blurRadius: 15,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Stack(
          children: [
            RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: false,
              filterQuality: FilterQuality.medium,
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    overlayColor.withOpacity(0.3),
                    Colors.transparent,
                    overlayColor.withOpacity(0.5),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: overlayColor.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.touch_app,
                        color: onSurfaceColor.withOpacity(0.9),
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Tap to expand',
                        style: TextStyle(
                          color: onSurfaceColor.withOpacity(0.9),
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: overlayColor.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.getActiveIndicatorColor(context),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDuration(_callDurationSeconds),
                      style: TextStyle(
                        color: onSurfaceColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatPanel() {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final overlayColor = AppTheme.getOverlayColor(context);
    
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.getBackgroundColor(context),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(
              color: primaryColor,
            ),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.arrow_back,
                      color: AppTheme.getOnPrimaryColor(context),
                      size: 28,
                    ),
                    onPressed: _toggleChat,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 16),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.getSecondaryColor(context).withOpacity(0.3),
                          AppTheme.getPrimaryColor(context).withOpacity(0.2),
                        ],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.person,
                      color: AppTheme.getOnPrimaryColor(context),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chat',
                          style: TextStyle(
                            color: AppTheme.getOnPrimaryColor(context),
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'ID: ${widget.remoteId}',
                          style: TextStyle(
                            color: AppTheme.getOnPrimaryColor(context).withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.getActiveIndicatorColor(context).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppTheme.getActiveIndicatorColor(context).withOpacity(0.5),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.getActiveIndicatorColor(context),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _formatDuration(_callDurationSeconds),
                          style: TextStyle(
                            color: AppTheme.getOnPrimaryColor(context),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: onSurfaceColor.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No messages yet',
                          style: TextStyle(
                            color: onSurfaceColor.withOpacity(0.7),
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Start chatting!',
                          style: TextStyle(
                            color: onSurfaceColor.withOpacity(0.5),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _chatScrollController,
                    padding: const EdgeInsets.only(right: 5,left: 5),
                    reverse: true, // Latest messages at bottom (like WhatsApp)
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMe = message.senderId == widget.myId;
                      return _buildMessageBubble(message, isMe);
                    },
                  ),
          ),

          // Call controls bar
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: overlayColor.withOpacity(0.4),
                border: Border(
                  top: BorderSide(color: onSurfaceColor.withOpacity(0.1), width: 1),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildMiniControlButton(
                    icon: _isCameraOn
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    onPressed: _toggleCamera,
                    isActive: _isCameraOn,
                  ),
                  _buildMiniControlButton(
                    icon: _isMicOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                    onPressed: _toggleMicrophone,
                    isActive: _isMicOn,
                  ),
                  _buildMiniControlButton(
                    icon: Icons.flip_camera_ios_rounded,
                    onPressed: _switchCamera,
                    isActive: true,
                  ),
                  _buildMiniEndCallButton(),
                ],
              ),
            ),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: overlayColor.withOpacity(0.3)),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(
                          color: primaryColor.withOpacity(0.5),
                          width: 1,
                        ),
                      ),
                      child: TextField(
                        controller: _messageController,
                        style: TextStyle(
                          color: onSurfaceColor, // text color
                        ),
                        cursorColor: primaryColor, // cursor color
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: TextStyle(
                            color: onSurfaceColor.withOpacity(0.5), // hint color
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false, // no background
                        ),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: primaryColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.send_rounded,
                        color: AppTheme.getOnPrimaryColor(context),
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, bool isMe) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final surfaceVariant = AppTheme.getSurfaceVariantColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    
    return Padding(
      padding: const EdgeInsets.only(top: 2,bottom: 2),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        // crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // if (!isMe) const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.65,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe ? primaryColor : surfaceVariant,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.message,
                    style: TextStyle(
                      color: isMe ? AppTheme.getOnPrimaryColor(context) : onSurfaceColor, 
                      fontSize: 15,
                    ),
                  ),
                  // const SizedBox(height: 4),
                  /*Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        _formatMessageTime(message.timestamp),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),*/
                ],
              ),
            ),
          ),
          // if (isMe) const SizedBox(width: 8),
        ],
      ),
    );
  }

  String _formatMessageTime(DateTime dateTime) {
    try {
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) {
        return 'Just now';
      } else if (difference.inHours < 1) {
        return '${difference.inMinutes}m ago';
      } else if (difference.inDays < 1) {
        return '${difference.inHours}h ago';
      } else {
        return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
      }
    } catch (e) {
      return '';
    }
  }

  Widget _buildMiniControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required bool isActive,
  }) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final errorColor = AppTheme.getErrorColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive
            ? primaryColor
            : errorColor.withOpacity(0.3),
        border: Border.all(
          color: isActive
              ? onSurfaceColor.withOpacity(0.3)
              : errorColor.withOpacity(0.5),
          width: 2,
        ),
      ),
      child: IconButton(
        icon: Icon(icon, size: 22),
        color: isActive ? AppTheme.getOnPrimaryColor(context) : onSurfaceColor,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildMiniEndCallButton() {
    final errorColor = AppTheme.getErrorColor(context);
    
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [errorColor, errorColor.withOpacity(0.8)],
        ),
      ),
      child: IconButton(
        icon: const Icon(Icons.call_end_rounded, size: 22),
        color: AppTheme.getOnErrorColor(context),
        onPressed: _endCall,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

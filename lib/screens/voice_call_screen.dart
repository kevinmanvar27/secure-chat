import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/webrtc_service.dart';
import '../services/chat_service.dart';
import '../services/call_request_service.dart';
import '../theme/app_theme.dart';
import 'dart:async';
import 'dart:math' as math;

/// Voice-only call screen with audio visualization
class VoiceCallScreen extends StatefulWidget {
  final String myId;
  final String remoteId;
  final String? roomId;
  final bool isCaller;

  const VoiceCallScreen({
    super.key,
    required this.myId,
    required this.remoteId,
    this.roomId,
    this.isCaller = true,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> with TickerProviderStateMixin {
  final WebRTCService _webrtcService = WebRTCService();
  final ChatService _chatService = ChatService();
  final CallRequestService _callRequestService = CallRequestService();
  
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  List<ChatMessage> _messages = [];
  bool _isChatVisible = false;
  int _unreadCount = 0;

  bool _isMicOn = true;
  bool _isSpeakerOn = true;
  bool _isCallActive = false;
  String _connectionStatus = 'Connecting...';

  late AnimationController _pulseController;
  late AnimationController _waveController;
  late Animation<double> _pulseAnimation;

  Timer? _callDurationTimer;
  int _callDurationSeconds = 0;
  StreamSubscription? _chatSubscription;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _disconnectSubscription;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _waveController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();

    _pulseAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initializeVoiceCall();
    _initializeChat();
  }

  @override
  void dispose() {
    _callDurationTimer?.cancel();
    _chatSubscription?.cancel();
    _remoteStreamSubscription?.cancel();
    _disconnectSubscription?.cancel();
    _pulseController.dispose();
    _waveController.dispose();
    _messageController.dispose();
    _chatScrollController.dispose();
    _webrtcService.dispose();
    _chatService.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  String get _effectiveRoomId {
    return widget.roomId ?? ([widget.myId, widget.remoteId]..sort()).join('_');
  }

  Future<void> _initializeVoiceCall() async {
    try {
      _updateStatus('Initializing audio...');

      await _webrtcService.resetConnectionWithoutStreamReinit();
      await _webrtcService.initializeLocalStream();

      // Voice call: mic ON, camera OFF
      _webrtcService.setMicEnabled(true);
      _webrtcService.setCameraEnabled(false);
      _isMicOn = true;

      // Setup listeners
      _setupStreamListeners();

      _updateStatus('Calling...');
      await _webrtcService.ensureLocalStreamReady();
      await _webrtcService.enableSpeakerphone(true);

      if (widget.isCaller) {
        await _webrtcService.createOffer(_effectiveRoomId, remoteUserId: widget.remoteId);
      } else {
        await _webrtcService.handleOffer(_effectiveRoomId, widget.remoteId);
      }
    } catch (e) {
      _showErrorAndExit('Voice call initialization failed: $e');
    }
  }

  void _setupStreamListeners() {
    _remoteStreamSubscription = _webrtcService.remoteStream.listen((stream) {
      if (mounted && stream.getAudioTracks().isNotEmpty) {
        setState(() {
          _isCallActive = true;
          _connectionStatus = 'Connected';
        });
        _startCallDurationTimer();
      }
    });

    _disconnectSubscription = _webrtcService.remoteDisconnect.listen((disconnected) {
      if (disconnected && mounted) {
        _showSnackBar('Call ended');
        Navigator.of(context).pop();
      }
    });
  }

  void _initializeChat() {
    _chatService.startListening(widget.myId, widget.remoteId);
    _chatSubscription = _chatService.messages.listen((messages) {
      if (mounted) {
        final newCount = messages.length - _messages.length;
        setState(() {
          if (!_isChatVisible && newCount > 0) {
            _unreadCount += newCount;
          }
          _messages = messages.reversed.toList(); // Reverse to show newest at bottom
        });
        _scrollToBottom();
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startCallDurationTimer() {
    _callDurationTimer?.cancel();
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDurationSeconds++;
        });
      }
    });
  }

  void _updateStatus(String status) {
    if (mounted) {
      setState(() {
        _connectionStatus = status;
      });
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _toggleMic() {
    setState(() {
      _isMicOn = !_isMicOn;
    });
    _webrtcService.setMicEnabled(_isMicOn);
  }

  void _toggleSpeaker() async {
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
    await _webrtcService.enableSpeakerphone(_isSpeakerOn);
  }

  void _toggleChat() {
    setState(() {
      _isChatVisible = !_isChatVisible;
      if (_isChatVisible) {
        _unreadCount = 0;
      }
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _chatService.sendMessage(widget.myId, widget.remoteId, text);
    _messageController.clear();
  }

  void _endCall() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End Call'),
        content: const Text('Are you sure you want to end this call?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('End Call'),
          ),
        ],
      ),
    );
  }

  void _showErrorAndExit(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
      Navigator.of(context).pop();
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = AppTheme.getPrimaryColor(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Main voice call UI
            _buildVoiceCallUI(primaryColor),

            // Chat panel
            if (_isChatVisible) _buildChatPanel(),

            // Top bar
            _buildTopBar(primaryColor),

            // Bottom controls
            _buildBottomControls(primaryColor),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceCallUI(Color primaryColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Audio visualization waves
          AnimatedBuilder(
            animation: _waveController,
            builder: (context, child) {
              return CustomPaint(
                size: const Size(200, 200),
                painter: AudioWavePainter(
                  progress: _waveController.value,
                  color: primaryColor,
                  isActive: _isCallActive,
                ),
              );
            },
          ),

          // Avatar
          ScaleTransition(
            scale: _pulseAnimation,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primaryColor,
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withOpacity(0.5),
                    blurRadius: 30,
                    spreadRadius: 10,
                  ),
                ],
              ),
              child: const Icon(
                Icons.person,
                size: 60,
                color: Colors.white,
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Remote user ID
          Text(
            widget.remoteId,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 8),

          // Status / Duration
          Text(
            _isCallActive ? _formatDuration(_callDurationSeconds) : _connectionStatus,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(Color primaryColor) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Back button
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _endCall,
            ),

            // Voice call indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: primaryColor.withOpacity(0.3),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(Icons.phone, color: primaryColor, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    'Voice Call',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),

            // Chat button with badge
            Stack(
              children: [
                IconButton(
                  icon: Icon(
                    _isChatVisible ? Icons.chat : Icons.chat_outlined,
                    color: Colors.white,
                  ),
                  onPressed: _toggleChat,
                ),
                if (_unreadCount > 0)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$_unreadCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls(Color primaryColor) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Mute button
            _buildControlButton(
              icon: _isMicOn ? Icons.mic : Icons.mic_off,
              label: _isMicOn ? 'Mute' : 'Unmute',
              isActive: _isMicOn,
              onPressed: _toggleMic,
            ),

            // End call button
            GestureDetector(
              onTap: _endCall,
              child: Container(
                width: 70,
                height: 70,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.call_end,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),

            // Speaker button
            _buildControlButton(
              icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
              label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
              isActive: _isSpeakerOn,
              onPressed: _toggleSpeaker,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isActive ? Colors.white.withOpacity(0.2) : Colors.red.withOpacity(0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel() {
    return Positioned(
      right: 0,
      top: 80,
      bottom: 120,
      width: MediaQuery.of(context).size.width * 0.85,
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            // Chat header
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Chat',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 20),
                    onPressed: _toggleChat,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            // Messages
            Expanded(
              child: ListView.builder(
                controller: _chatScrollController,
                padding: const EdgeInsets.all(8),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  final isMe = message.senderId == widget.myId;
                  return _buildMessageBubble(message, isMe);
                },
              ),
            ),

            // Input
            Container(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.1),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.send, color: AppTheme.getPrimaryColor(context)),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, bool isMe) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.6,
        ),
        decoration: BoxDecoration(
          color: isMe ? primaryColor : Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message.message,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }
}

/// Custom painter for audio wave visualization
class AudioWavePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isActive;

  AudioWavePainter({
    required this.progress,
    required this.color,
    required this.isActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!isActive) return;

    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Draw multiple expanding circles
    for (int i = 0; i < 3; i++) {
      final offset = (progress + i * 0.33) % 1.0;
      final radius = 60 + (offset * 40);
      final opacity = (1 - offset) * 0.5;
      
      paint.color = color.withOpacity(opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(AudioWavePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isActive != isActive;
  }
}

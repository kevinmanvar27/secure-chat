import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import '../services/webrtc_service.dart';
import '../theme/app_theme.dart';
import 'dart:async';

/// Voice-only call screen - simple UI like real phone call
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

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  final WebRTCService _webrtcService = WebRTCService();
  
  bool _isMicOn = true;
  bool _isSpeakerOn = false; // Default earpiece mode
  bool _isCallActive = false;
  bool _isNear = false; // Proximity sensor state
  String _connectionStatus = 'Connecting...';

  Timer? _callDurationTimer;
  int _callDurationSeconds = 0;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _disconnectSubscription;
  StreamSubscription? _proximitySubscription;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initializeProximitySensor();
    _initializeVoiceCall();
  }

  @override
  void dispose() {
    _callDurationTimer?.cancel();
    _remoteStreamSubscription?.cancel();
    _disconnectSubscription?.cancel();
    _proximitySubscription?.cancel();
    _webrtcService.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  String get _effectiveRoomId {
    return widget.roomId ?? ([widget.myId, widget.remoteId]..sort()).join('_');
  }

  /// Initialize proximity sensor for screen on/off like real call
  void _initializeProximitySensor() {
    _proximitySubscription = ProximitySensor.events.listen((int event) {
      if (mounted) {
        setState(() {
          _isNear = event > 0;
        });
        
        // Turn screen off when near ear, on when away
        if (_isNear) {
          WakelockPlus.disable();
        } else {
          WakelockPlus.enable();
        }
      }
    });
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
      
      // Default to earpiece mode
      await _webrtcService.enableSpeakerphone(false);

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

  void _endCall() {
    Navigator.of(context).pop();
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

    // Show black screen when phone is near ear
    if (_isNear) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top spacer
            const Spacer(flex: 2),

            // Avatar - Simple, no animation
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primaryColor,
              ),
              child: const Icon(
                Icons.person,
                size: 60,
                color: Colors.white,
              ),
            ),

            const SizedBox(height: 24),

            // Remote user ID
            Text(
              widget.remoteId,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            // Status / Duration
            Text(
              _isCallActive ? _formatDuration(_callDurationSeconds) : _connectionStatus,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 18,
              ),
            ),

            // Bottom spacer
            const Spacer(flex: 3),

            // Bottom controls
            Padding(
              padding: const EdgeInsets.only(bottom: 50),
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
                    icon: _isSpeakerOn ? Icons.volume_up : Icons.hearing,
                    label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                    isActive: _isSpeakerOn,
                    onPressed: _toggleSpeaker,
                  ),
                ],
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
}

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:async';

/// Singleton WebRTC Service - persists connection until app closes
class WebRTCService {
  // Singleton instance
  static final WebRTCService _instance = WebRTCService._internal();
  
  factory WebRTCService() {
    return _instance;
  }
  
  WebRTCService._internal();
  
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final DatabaseReference _database = FirebaseDatabase.instance.ref();

  // Use late initialization so we can recreate if closed
  StreamController<MediaStream> _localStreamController = StreamController<MediaStream>.broadcast();
  StreamController<MediaStream> _remoteStreamController = StreamController<MediaStream>.broadcast();
  StreamController<bool> _remoteDisconnectController = StreamController<bool>.broadcast();

  Stream<MediaStream> get localStream => _localStreamController.stream;
  Stream<MediaStream> get remoteStream => _remoteStreamController.stream;
  Stream<bool> get remoteDisconnect => _remoteDisconnectController.stream;
  
  /// Ensure stream controllers are open (recreate if closed)
  void _ensureControllersOpen() {
    if (_localStreamController.isClosed) {
      _localStreamController = StreamController<MediaStream>.broadcast();
    }
    if (_remoteStreamController.isClosed) {
      _remoteStreamController = StreamController<MediaStream>.broadcast();
    }
    if (_remoteDisconnectController.isClosed) {
      _remoteDisconnectController = StreamController<bool>.broadcast();
    }
  }
  MediaStream? get currentLocalStream => _localStream;
  MediaStream? get currentRemoteStream => _remoteStream;
  
  // Check if connection is active
  bool get isConnected => _isConnected;
  bool get hasActiveConnection => _peerConnection != null && _isConnected;

  StreamSubscription? _presenceSubscription;
  StreamSubscription? _offerSubscription;
  StreamSubscription? _answerSubscription;
  StreamSubscription? _iceSubscription;
  
  bool _isConnected = false;
  Timer? _disconnectTimer;
  Timer? _connectionTimeout;
  
  // Track current room ID for cleanup
  String? _currentRoomId;

  // Better ICE servers with multiple STUN and TURN for reliability
  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      // Multiple STUN servers for redundancy
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      // Free TURN servers for NAT traversal
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'iceCandidatePoolSize': 10,
    'iceTransportPolicy': 'all',
  };

  final Map<String, dynamic> _mediaConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'googEchoCancellation': true,
      'googAutoGainControl': true,
      'googNoiseSuppression': true,
      'googHighpassFilter': true,
      'googTypingNoiseDetection': true,
      'googAudioMirroring': false,
    },
    'video': {
      'facingMode': 'user',
      'width': {'ideal': 1280},
      'height': {'ideal': 720},
      'frameRate': {'ideal': 30},
    }
  };

  final Map<String, dynamic> _offerAnswerConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': [],
  };

  Future<void> initializeLocalStream() async {
    try {
      print('📹 Initializing local stream...');
      
      // Ensure stream controllers are open
      _ensureControllersOpen();
      
      // Dispose old stream if exists
      if (_localStream != null) {
        print('  Disposing existing stream...');
        try {
          _localStream!.getTracks().forEach((track) => track.stop());
          await _localStream!.dispose();
        } catch (e) {
          // Ignore disposal errors
        }
        _localStream = null;
      }
      
      _localStream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);

      _localStream!.getAudioTracks().forEach((track) {
        track.enabled = true;
      });
      _localStream!.getVideoTracks().forEach((track) {
        track.enabled = true;
      });

      print('  ✓ Local stream initialized: ${_localStream!.getTracks().length} tracks');
      _localStreamController.add(_localStream!);
    } catch (e) {
      print('❌ Error initializing local stream: $e');
    }
  }
  
  /// Ensure local stream is ready with valid tracks
  /// Call this before any WebRTC operations that require the local stream
  Future<void> ensureLocalStreamReady() async {
    print('📹 ensureLocalStreamReady called');
    
    // Check if stream exists and has valid tracks
    if (_localStream == null) {
      print('  Stream is null, initializing...');
      await initializeLocalStream();
      return;
    }
    
    // Check if tracks are valid
    final videoTracks = _localStream!.getVideoTracks();
    final audioTracks = _localStream!.getAudioTracks();
    
    if (videoTracks.isEmpty || audioTracks.isEmpty) {
      print('  Stream has missing tracks (video: ${videoTracks.length}, audio: ${audioTracks.length}), reinitializing...');
      await initializeLocalStream();
      return;
    }
    
    // Check if tracks are still active (not ended)
    bool hasValidVideo = videoTracks.any((t) => t.enabled != null);
    bool hasValidAudio = audioTracks.any((t) => t.enabled != null);
    
    if (!hasValidVideo || !hasValidAudio) {
      print('  Stream has invalid tracks, reinitializing...');
      await initializeLocalStream();
      return;
    }
    
    print('  ✓ Local stream is ready (${_localStream!.getTracks().length} tracks)');
  }

  void _startConnectionTimeout() {
    _connectionTimeout?.cancel();
    _connectionTimeout = Timer(const Duration(seconds: 15), () {
      if (!_isConnected) {
        print('Connection timeout - triggering disconnect');
        _remoteDisconnectController.add(true);
      }
    });
  }

  void _cancelConnectionTimeout() {
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
  }

  Future<void> _setupPresenceTracking(String roomId, String remoteUserId) async {
    try {
      final presenceRef = _database.child('presence/$remoteUserId');
      bool _initialCheckDone = false;
      
      _presenceSubscription?.cancel();
      _presenceSubscription = presenceRef.onValue.listen((event) {
        // Only trigger disconnect after connection is established and initial check is done
        if (_initialCheckDone && _isConnected && !event.snapshot.exists) {
          _remoteDisconnectController.add(true);
        }
        _initialCheckDone = true;
      });
    } catch (e) {
      print('Error setting up presence tracking: $e');
    }
  }

  /// Unified peer connection creation for both caller and receiver
  Future<void> _createPeerConnection(String roomId, String? remoteUserId, {required bool isCaller}) async {
    try {
      print('🔧 Creating peer connection for room: $roomId, isCaller: $isCaller');
      
      // Ensure local stream is ready before creating peer connection
      await ensureLocalStreamReady();
      print('📹 Local stream verified: ${_localStream?.getTracks().length ?? 0} tracks');
      
      _peerConnection = await createPeerConnection(_iceServers);

      if (remoteUserId != null) {
        _setupPresenceTracking(roomId, remoteUserId);
      }

      // Add local tracks to peer connection
      final tracks = _localStream?.getTracks() ?? [];
      print('📹 Adding ${tracks.length} tracks to peer connection');
      
      for (var track in tracks) {
        await _peerConnection?.addTrack(track, _localStream!);
        print('  ✓ Added track: ${track.kind}');
      }
      
      if (tracks.isEmpty) {
        print('⚠️ WARNING: No tracks added to peer connection!');
      }

      _peerConnection!.onTrack = (RTCTrackEvent event) {
        print('🎥 onTrack received! streams=${event.streams.length}, tracks=${event.track.kind}');
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _isConnected = true;
          _cancelConnectionTimeout();
          print('🎥 Remote stream set with ${_remoteStream!.getTracks().length} tracks');
          print('🎥 Video tracks: ${_remoteStream!.getVideoTracks().length}');
          print('🎥 Audio tracks: ${_remoteStream!.getAudioTracks().length}');
          print('🎥 Notifying listeners via stream controller...');
          _remoteStreamController.add(_remoteStream!);
          print('🎥 Listeners notified!');
        } else {
          print('⚠️ onTrack received but no streams!');
        }
      };

      // ICE candidate handling - different paths for caller/receiver
      final myRole = isCaller ? 'caller' : 'receiver';
      final remoteRole = isCaller ? 'receiver' : 'caller';
      
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          _database
              .child('webrtc_signaling/$roomId/$myRole/ice_candidates')
              .push()
              .set({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }).catchError((error) {
            print('Error saving ICE candidate: $error');
          });
        }
      };

      _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
        print('ICE gathering state: $state');
      };

      _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        print('Connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _isConnected = true;
          _cancelConnectionTimeout();
          _disconnectTimer?.cancel();
          _disconnectTimer = null;
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          // Failed is a permanent state, disconnect immediately
          _disconnectTimer?.cancel();
          _cancelConnectionTimeout();
          _remoteDisconnectController.add(true);
        } else if (_isConnected && 
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // Disconnected can be temporary (network hiccup), wait before triggering disconnect
          _disconnectTimer?.cancel();
          _disconnectTimer = Timer(const Duration(seconds: 5), () {
            if (_peerConnection?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
              _remoteDisconnectController.add(true);
            }
          });
        }
      };

      // Listen for remote ICE candidates
      _listenForIceCandidates(roomId, remoteRole);
    } catch (e) {
      print('Error creating peer connection: $e');
    }
  }

  void _listenForIceCandidates(String roomId, String role) {
    _iceSubscription?.cancel();
    _iceSubscription = _database
        .child('webrtc_signaling/$roomId/$role/ice_candidates')
        .onChildAdded
        .listen((event) async {
      try {
        if (_peerConnection == null) return;
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        final candidate = RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        );
        await _peerConnection?.addCandidate(candidate);
      } catch (e) {
        print('Error adding ICE candidate: $e');
      }
    });
  }

  Future<void> createOffer(String roomId, {String? remoteUserId}) async {
    try {
      print('Creating offer for room: $roomId');
      
      // Ensure stream controllers are open
      _ensureControllersOpen();
      
      // Store room ID for cleanup
      _currentRoomId = roomId;
      
      // IMPORTANT: Ensure local stream is valid before creating offer
      if (_localStream == null || _localStream!.getTracks().isEmpty) {
        print('⚠️ Local stream is null or empty, reinitializing...');
        await _reinitializeLocalStream();
        if (_localStream == null || _localStream!.getTracks().isEmpty) {
          print('❌ Failed to initialize local stream');
          _remoteDisconnectController.add(true);
          return;
        }
      }
      
      // Start connection timeout
      _startConnectionTimeout();
      
      // ALWAYS create fresh peer connection for new call
      if (_peerConnection != null) {
        try {
          await _peerConnection!.close();
        } catch (e) {
          // Ignore
        }
        _peerConnection = null;
      }
      
      await _createPeerConnection(roomId, remoteUserId, isCaller: true);

      RTCSessionDescription offer =
          await _peerConnection!.createOffer(_offerAnswerConstraints);
      await _peerConnection!.setLocalDescription(offer);
      print('Local description set for caller');

      await _database.child('webrtc_signaling/$roomId/offer').set({
        'type': offer.type,
        'sdp': offer.sdp,
      });
      print('Offer saved to database');

      _listenForAnswer(roomId);
    } catch (e) {
      print('Error creating offer: $e');
      _cancelConnectionTimeout();
      _remoteDisconnectController.add(true);
    }
  }

  void _listenForAnswer(String roomId) {
    bool _hasProcessedAnswer = false;
    
    _answerSubscription?.cancel();
    _answerSubscription = _database.child('webrtc_signaling/$roomId/answer').onValue.listen((event) async {
      try {
        if (event.snapshot.value != null && !_hasProcessedAnswer) {
          _hasProcessedAnswer = true;
          print('Received answer, processing...');
          
          final data = event.snapshot.value as Map<dynamic, dynamic>;
          final answer = RTCSessionDescription(
            data['sdp'],
            data['type'],
          );
          await _peerConnection?.setRemoteDescription(answer);
          print('Remote description set for caller - connection should establish');
        }
      } catch (e) {
        print('Error processing answer: $e');
        _hasProcessedAnswer = false; // Allow retry on error
      }
    });
  }

  Future<void> handleOffer(String roomId, String remoteUserId) async {
    bool _hasProcessedOffer = false;
    
    try {
      // Ensure stream controllers are open
      _ensureControllersOpen();
      
      // Store room ID for cleanup
      _currentRoomId = roomId;
      
      // IMPORTANT: Ensure local stream is valid before handling offer
      if (_localStream == null || _localStream!.getTracks().isEmpty) {
        print('⚠️ Local stream is null or empty, reinitializing...');
        await _reinitializeLocalStream();
        if (_localStream == null || _localStream!.getTracks().isEmpty) {
          print('❌ Failed to initialize local stream');
          _remoteDisconnectController.add(true);
          return;
        }
      }
      
      // Start connection timeout
      _startConnectionTimeout();
      
      // ALWAYS create fresh peer connection for new call
      if (_peerConnection != null) {
        try {
          await _peerConnection!.close();
        } catch (e) {
          // Ignore
        }
        _peerConnection = null;
      }
      
      await _createPeerConnection(roomId, remoteUserId, isCaller: false);
      print('Peer connection created for receiver, listening for offer on room: $roomId');

      _offerSubscription?.cancel();
      _offerSubscription = _database.child('webrtc_signaling/$roomId/offer').onValue.listen((event) async {
        try {
          if (event.snapshot.value != null && !_hasProcessedOffer) {
            _hasProcessedOffer = true;
            print('Received offer, processing...');
            
            final data = event.snapshot.value as Map<dynamic, dynamic>;
            final offer = RTCSessionDescription(
              data['sdp'],
              data['type'],
            );

            await _peerConnection?.setRemoteDescription(offer);
            print('Remote description set');

            RTCSessionDescription answer =
                await _peerConnection!.createAnswer(_offerAnswerConstraints);
            await _peerConnection!.setLocalDescription(answer);
            print('Local description set');

            await _database.child('webrtc_signaling/$roomId/answer').set({
              'type': answer.type,
              'sdp': answer.sdp,
            }).catchError((error) {
              print('Error saving answer: $error');
            });
            print('Answer sent');
          }
        } catch (e) {
          print('Error processing offer: $e');
          _hasProcessedOffer = false; // Allow retry on error
        }
      });
    } catch (e) {
      print('Error in handleOffer: $e');
      _cancelConnectionTimeout();
    }
  }

  Future<void> switchCamera() async {
    if (_localStream != null) {
      final videoTrack = _localStream!.getVideoTracks().first;
      await Helper.switchCamera(videoTrack);
    }
  }

  void toggleCamera() {
    if (_localStream != null && _localStream!.getVideoTracks().isNotEmpty) {
      final videoTrack = _localStream!.getVideoTracks()[0];
      videoTrack.enabled = !videoTrack.enabled;
    }
  }

  void toggleMicrophone() {
    if (_localStream != null && _localStream!.getAudioTracks().isNotEmpty) {
      final audioTrack = _localStream!.getAudioTracks()[0];
      audioTrack.enabled = !audioTrack.enabled;
    }
  }

  /// Get actual mic state from WebRTC
  bool get isMicEnabled {
    if (_localStream != null && _localStream!.getAudioTracks().isNotEmpty) {
      return _localStream!.getAudioTracks()[0].enabled;
    }
    return false;
  }

  /// Get actual camera state from WebRTC
  bool get isCameraEnabled {
    if (_localStream != null && _localStream!.getVideoTracks().isNotEmpty) {
      return _localStream!.getVideoTracks()[0].enabled;
    }
    return false;
  }

  /// Set mic state directly
  void setMicEnabled(bool enabled) {
    if (_localStream != null && _localStream!.getAudioTracks().isNotEmpty) {
      _localStream!.getAudioTracks()[0].enabled = enabled;
    }
  }

  /// Set camera state directly
  void setCameraEnabled(bool enabled) {
    if (_localStream != null && _localStream!.getVideoTracks().isNotEmpty) {
      _localStream!.getVideoTracks()[0].enabled = enabled;
    }
  }

  Future<void> toggleAudio(bool enabled) async {
    if (_localStream != null) {
      _localStream!.getAudioTracks().forEach((track) {
        track.enabled = enabled;
      });
    }
  }

  Future<void> toggleVideo(bool enabled) async {
    if (_localStream != null) {
      _localStream!.getVideoTracks().forEach((track) {
        track.enabled = enabled;
      });
    }
  }

  /// Enable speakerphone - routes audio to speaker
  Future<void> enableSpeakerphone(bool enable) async {
    try {
      await Helper.setSpeakerphoneOn(enable);
      print('🔊 Speakerphone ${enable ? "ON" : "OFF"}');
    } catch (e) {
      print('❌ Error setting speakerphone: $e');
    }
  }

  /// Check if speakerphone is enabled
  bool _isSpeakerOn = false;
  bool get isSpeakerOn => _isSpeakerOn;

  /// Toggle speakerphone
  Future<void> toggleSpeakerphone() async {
    _isSpeakerOn = !_isSpeakerOn;
    await enableSpeakerphone(_isSpeakerOn);
  }

  /// Set audio output to Bluetooth/Speaker/Earpiece
  /// This ensures audio goes to connected Bluetooth devices
  Future<void> setAudioOutputToDefault() async {
    try {
      // Setting speakerphone OFF allows system to route to Bluetooth if connected
      await Helper.setSpeakerphoneOn(false);
      _isSpeakerOn = false;
      print('🎧 Audio output set to default (Bluetooth/Earpiece)');
    } catch (e) {
      print('❌ Error setting audio output: $e');
    }
  }

  /// Force audio to speaker (ignores Bluetooth)
  Future<void> setAudioOutputToSpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(true);
      _isSpeakerOn = true;
      print('🔊 Audio output forced to speaker');
    } catch (e) {
      print('❌ Error setting audio to speaker: $e');
    }
  }

  Future<void> endCall(String roomId) async {
    print('📞 endCall: Ending call for room $roomId');
    try {
      // Remove signaling data from Firebase IMMEDIATELY
      await _cleanupSignalingData(roomId);
      
      // Reset connection state for next call
      await resetConnection();
      print('📞 endCall: Complete');
    } catch (e) {
      print('❌ Error ending call: $e');
    }
  }
  
  /// Clean up all signaling data from Firebase
  Future<void> _cleanupSignalingData(String? roomId) async {
    if (roomId == null) return;
    
    try {
      // Remove all signaling data for this room
      await _database.child('webrtc_signaling/$roomId').remove();
      print('🧹 Cleaned signaling data for room: $roomId');
    } catch (e) {
      print('Error cleaning signaling data: $e');
    }
  }
  
  /// Reset connection for a new call (without disposing streams)
  Future<void> resetConnection() async {
    print('🔄 resetConnection: Starting full reset...');
    _isConnected = false;
    
    // IMPORTANT: Clean up signaling data FIRST
    if (_currentRoomId != null) {
      await _cleanupSignalingData(_currentRoomId);
      _currentRoomId = null;
    }
    
    // Cancel all timers
    _cancelConnectionTimeout();
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    
    // Cancel all subscriptions FIRST
    _presenceSubscription?.cancel();
    _presenceSubscription = null;
    _offerSubscription?.cancel();
    _offerSubscription = null;
    _answerSubscription?.cancel();
    _answerSubscription = null;
    _iceSubscription?.cancel();
    _iceSubscription = null;
    
    // Stop all remote stream tracks to prevent freeze
    if (_remoteStream != null) {
      try {
        _remoteStream!.getTracks().forEach((track) {
          track.stop();
        });
      } catch (e) {
        // Ignore errors
      }
      _remoteStream = null;
    }
    
    // Close peer connection but keep local stream
    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
      } catch (e) {
        // Ignore errors
      }
      _peerConnection = null;
    }
    
    // IMPORTANT: Reinitialize local stream for fresh tracks
    // This ensures tracks are valid for the next peer connection
    await _reinitializeLocalStream();
    print('🔄 resetConnection: Complete');
  }
  
  /// Reset connection WITHOUT reinitializing local stream
  /// Use this when you want to keep the local stream intact
  Future<void> resetConnectionWithoutStreamReinit() async {
    print('🔄 Resetting connection (keeping local stream)...');
    _isConnected = false;
    
    // Clean up signaling data
    if (_currentRoomId != null) {
      await _cleanupSignalingData(_currentRoomId);
      _currentRoomId = null;
    }
    
    // Cancel all timers
    _cancelConnectionTimeout();
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    
    // Cancel all subscriptions
    _presenceSubscription?.cancel();
    _presenceSubscription = null;
    _offerSubscription?.cancel();
    _offerSubscription = null;
    _answerSubscription?.cancel();
    _answerSubscription = null;
    _iceSubscription?.cancel();
    _iceSubscription = null;
    
    // Stop remote stream
    if (_remoteStream != null) {
      try {
        _remoteStream!.getTracks().forEach((track) => track.stop());
      } catch (e) {}
      _remoteStream = null;
    }
    
    // Close peer connection
    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
      } catch (e) {}
      _peerConnection = null;
    }
    
    // NOTE: We intentionally DO NOT dispose local stream here
    // The local stream will be reused for the next connection
    print('✓ Connection reset complete (local stream preserved: ${_localStream != null})');
  }
  
  /// Reinitialize local stream with fresh tracks
  Future<void> _reinitializeLocalStream() async {
    try {
      print('🔄 Reinitializing local stream...');
      
      // Ensure stream controllers are open
      _ensureControllersOpen();
      
      // Dispose old local stream tracks
      if (_localStream != null) {
        print('  Disposing old stream with ${_localStream!.getTracks().length} tracks');
        _localStream!.getTracks().forEach((track) {
          track.stop();
        });
        await _localStream!.dispose();
        _localStream = null;
      }
      
      // Create fresh local stream
      print('  Creating new media stream...');
      _localStream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);
      
      final audioTracks = _localStream!.getAudioTracks();
      final videoTracks = _localStream!.getVideoTracks();
      print('  ✓ New stream created: ${audioTracks.length} audio, ${videoTracks.length} video tracks');
      
      for (var track in audioTracks) {
        track.enabled = true;
      }
      for (var track in videoTracks) {
        track.enabled = true;
      }
      
      // Notify listeners of new local stream
      _localStreamController.add(_localStream!);
      print('  ✓ Local stream reinitialized successfully');
    } catch (e) {
      print('❌ Error reinitializing local stream: $e');
    }
  }
  
  /// Full cleanup - only call when app is closing
  void dispose() {
    _isConnected = false;
    _cancelConnectionTimeout();
    _disconnectTimer?.cancel();
    _presenceSubscription?.cancel();
    _offerSubscription?.cancel();
    _answerSubscription?.cancel();
    _iceSubscription?.cancel();
    _localStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    _localStreamController.close();
    _remoteStreamController.close();
    _remoteDisconnectController.close();
  }
}

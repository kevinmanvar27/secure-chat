import 'package:flutter_webrtc/flutter_webrtc.dart';
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

  final _localStreamController = StreamController<MediaStream>.broadcast();
  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  
  final _remoteDisconnectController = StreamController<bool>.broadcast();

  Stream<MediaStream> get localStream => _localStreamController.stream;
  Stream<MediaStream> get remoteStream => _remoteStreamController.stream;
  Stream<bool> get remoteDisconnect => _remoteDisconnectController.stream;
  
  MediaStream? get currentLocalStream => _localStream;
  MediaStream? get currentRemoteStream => _remoteStream;
  
  // Check if connection is active
  bool get isConnected => _isConnected;
  bool get hasActiveConnection => _peerConnection != null && _isConnected;

  StreamSubscription? _presenceSubscription;
  bool _isConnected = false;
  Timer? _disconnectTimer;

  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ]
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
      _localStream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);

      _localStream!.getAudioTracks().forEach((track) {
        track.enabled = true;
      });
      _localStream!.getVideoTracks().forEach((track) {
        track.enabled = true;
      });

      _localStreamController.add(_localStream!);
    } catch (e) {
    }
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
    }
  }

  Future<void> _createPeerConnection(String roomId, String remoteUserId) async {
    try {
      _peerConnection = await createPeerConnection(_iceServers);

      _setupPresenceTracking(roomId, remoteUserId);

      _localStream?.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _isConnected = true;
          _remoteStreamController.add(_remoteStream!);
        }
      };

      // Receiver sends ICE candidates to 'receiver' path
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          _database
              .child('webrtc_signaling/$roomId/receiver/ice_candidates')
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

      _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        print('Connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _isConnected = true;
          _disconnectTimer?.cancel();
          _disconnectTimer = null;
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          // Failed is a permanent state, disconnect immediately
          _disconnectTimer?.cancel();
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

      // Receiver listens for caller's ICE candidates
      _listenForIceCandidates(roomId, 'caller');
    } catch (e) {
      print('Error creating peer connection: $e');
    }
  }

  void _listenForIceCandidates(String roomId, String role) {
    _database
        .child('webrtc_signaling/$roomId/$role/ice_candidates')
        .onChildAdded
        .listen((event) async {
      try {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        final candidate = RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        );
        await _peerConnection?.addCandidate(candidate);
      } catch (e) {
      }
    });
  }

  Future<void> createOffer(String roomId, {String? remoteUserId}) async {
    try {
      print('Creating offer for room: $roomId');
      
      // Create peer connection first if not already created
      if (_peerConnection == null) {
        await _createPeerConnectionForCaller(roomId, remoteUserId);
      }

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
    }
  }

  Future<void> _createPeerConnectionForCaller(String roomId, String? remoteUserId) async {
    try {
      _peerConnection = await createPeerConnection(_iceServers);

      if (remoteUserId != null) {
        _setupPresenceTracking(roomId, remoteUserId);
      }

      _localStream?.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _isConnected = true;
          _remoteStreamController.add(_remoteStream!);
        }
      };

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          _database
              .child('webrtc_signaling/$roomId/caller/ice_candidates')
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

      _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        print('Connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _isConnected = true;
          _disconnectTimer?.cancel();
          _disconnectTimer = null;
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          // Failed is a permanent state, disconnect immediately
          _disconnectTimer?.cancel();
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

      _listenForIceCandidates(roomId, 'receiver');
    } catch (e) {
      print('Error creating peer connection for caller: $e');
    }
  }

  void _listenForAnswer(String roomId) {
    bool _hasProcessedAnswer = false;
    
    _database.child('webrtc_signaling/$roomId/answer').onValue.listen((event) async {
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
      await _createPeerConnection(roomId, remoteUserId);
      print('Peer connection created for receiver, listening for offer on room: $roomId');

      _database.child('webrtc_signaling/$roomId/offer').onValue.listen((event) async {
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

  Future<void> endCall(String roomId) async {
    try {
      await _database.child('webrtc_signaling/$roomId').remove().catchError((error) {
      });
      
      // Reset connection state for next call
      await resetConnection();
    } catch (e) {
    }
  }
  
  /// Reset connection for a new call (without disposing streams)
  Future<void> resetConnection() async {
    _isConnected = false;
    _presenceSubscription?.cancel();
    _presenceSubscription = null;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    
    // Close peer connection but keep local stream
    await _peerConnection?.close();
    _peerConnection = null;
    
    // Clear remote stream
    _remoteStream = null;
  }
  
  /// Full cleanup - only call when app is closing
  void dispose() {
    _isConnected = false;
    _presenceSubscription?.cancel();
    _disconnectTimer?.cancel();
    _localStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    _localStreamController.close();
    _remoteStreamController.close();
    _remoteDisconnectController.close();
  }
}

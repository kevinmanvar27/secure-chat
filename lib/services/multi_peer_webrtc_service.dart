import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

class MultiPeerWebRTCService {
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  
  MediaStream? _localStream;
  
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  
  final _localStreamController = StreamController<MediaStream>.broadcast();
  final _remoteStreamsController = StreamController<Map<String, MediaStream>>.broadcast();
  final _peerDisconnectController = StreamController<String>.broadcast();
  
  Stream<MediaStream> get localStream => _localStreamController.stream;
  Stream<Map<String, MediaStream>> get remoteStreams => _remoteStreamsController.stream;
  Stream<String> get peerDisconnect => _peerDisconnectController.stream;
  
  MediaStream? get currentLocalStream => _localStream;
  Map<String, MediaStream> get currentRemoteStreams => Map.from(_remoteStreams);
  
  final Map<String, StreamSubscription> _subscriptions = {};
  
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
      rethrow;
    }
  }
  
  Future<void> connectToPeer(String roomId, String myId, String peerId) async {
    if (_peerConnections.containsKey(peerId)) {
      return;
    }
    
    try {
      final pc = await createPeerConnection(_iceServers);
      _peerConnections[peerId] = pc;
      
      if (_localStream != null) {
        _localStream!.getTracks().forEach((track) {
          pc.addTrack(track, _localStream!);
        });
      }
      
      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStreams[peerId] = event.streams[0];
          
          event.streams[0].getAudioTracks().forEach((track) {
            track.enabled = true;
          });
          event.streams[0].getVideoTracks().forEach((track) {
            track.enabled = true;
          });
          
          _remoteStreamsController.add(Map.from(_remoteStreams));
        }
      };
      
      pc.onConnectionState = (RTCPeerConnectionState state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _peerDisconnectController.add(peerId);
          _removePeer(peerId);
        }
      };
      
      pc.onIceCandidate = (RTCIceCandidate candidate) async {
        if (candidate.candidate != null) {
          try {
            await _database
                .child('webrtc_signaling/$roomId/peers/$myId/ice_candidates/$peerId')
                .push()
                .set({
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            });
          } catch (e) {
          }
        }
      };
      
      final offer = await pc.createOffer(_offerAnswerConstraints);
      await pc.setLocalDescription(offer);
      
      await _database
          .child('webrtc_signaling/$roomId/peers/$myId/offers/$peerId')
          .set({
        'sdp': offer.sdp,
        'type': offer.type,
      });
      
      _listenForAnswer(roomId, myId, peerId);
      _listenForIceCandidates(roomId, myId, peerId);
      
    } catch (e) {
      _peerConnections.remove(peerId);
      rethrow;
    }
  }
  
  Future<void> handleOffer(String roomId, String myId, String peerId, Map<dynamic, dynamic> offerData) async {
    if (_peerConnections.containsKey(peerId)) {
      return;
    }
    
    try {
      final pc = await createPeerConnection(_iceServers);
      _peerConnections[peerId] = pc;
      
      if (_localStream != null) {
        _localStream!.getTracks().forEach((track) {
          pc.addTrack(track, _localStream!);
        });
      }
      
      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStreams[peerId] = event.streams[0];
          
          event.streams[0].getAudioTracks().forEach((track) {
            track.enabled = true;
          });
          event.streams[0].getVideoTracks().forEach((track) {
            track.enabled = true;
          });
          
          _remoteStreamsController.add(Map.from(_remoteStreams));
        }
      };
      
      pc.onConnectionState = (RTCPeerConnectionState state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _peerDisconnectController.add(peerId);
          _removePeer(peerId);
        }
      };
      
      pc.onIceCandidate = (RTCIceCandidate candidate) async {
        if (candidate.candidate != null) {
          try {
            await _database
                .child('webrtc_signaling/$roomId/peers/$myId/ice_candidates/$peerId')
                .push()
                .set({
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            });
          } catch (e) {
          }
        }
      };
      
      final offer = RTCSessionDescription(offerData['sdp'], offerData['type']);
      await pc.setRemoteDescription(offer);
      
      final answer = await pc.createAnswer(_offerAnswerConstraints);
      await pc.setLocalDescription(answer);
      
      await _database
          .child('webrtc_signaling/$roomId/peers/$myId/answers/$peerId')
          .set({
        'sdp': answer.sdp,
        'type': answer.type,
      });
      
      _listenForIceCandidates(roomId, myId, peerId);
      
    } catch (e) {
      _peerConnections.remove(peerId);
      rethrow;
    }
  }
  
  void _listenForAnswer(String roomId, String myId, String peerId) {
    final key = 'answer_$peerId';
    
    _subscriptions[key] = _database
        .child('webrtc_signaling/$roomId/peers/$peerId/answers/$myId')
        .onValue
        .listen((event) async {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        
        final pc = _peerConnections[peerId];
        if (pc != null) {
          final answer = RTCSessionDescription(data['sdp'], data['type']);
          await pc.setRemoteDescription(answer);
        }
      }
    });
  }
  
  void _listenForIceCandidates(String roomId, String myId, String peerId) {
    final key = 'ice_$peerId';
    
    _subscriptions[key] = _database
        .child('webrtc_signaling/$roomId/peers/$peerId/ice_candidates/$myId')
        .onChildAdded
        .listen((event) async {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        
        final pc = _peerConnections[peerId];
        if (pc != null) {
          try {
            final candidate = RTCIceCandidate(
              data['candidate'],
              data['sdpMid'],
              data['sdpMLineIndex'],
            );
            await pc.addCandidate(candidate);
          } catch (e) {
          }
        }
      }
    });
  }
  
  void listenForOffers(String roomId, String myId) {
    _subscriptions['offers'] = _database
        .child('webrtc_signaling/$roomId/peers')
        .onChildAdded
        .listen((event) {
      final peerId = event.snapshot.key;
      if (peerId != null && peerId != myId) {
        _database
            .child('webrtc_signaling/$roomId/peers/$peerId/offers/$myId')
            .onValue
            .listen((offerEvent) async {
          if (offerEvent.snapshot.value != null) {
            final offerData = offerEvent.snapshot.value as Map<dynamic, dynamic>;
            await handleOffer(roomId, myId, peerId, offerData);
          }
        });
      }
    });
  }
  
  void _removePeer(String peerId) {
    _peerConnections[peerId]?.close();
    _peerConnections.remove(peerId);
    
    _remoteStreams[peerId]?.dispose();
    _remoteStreams.remove(peerId);
    
    _remoteStreamsController.add(Map.from(_remoteStreams));
    
    _subscriptions.remove('answer_$peerId')?.cancel();
    _subscriptions.remove('ice_$peerId')?.cancel();
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
  
  Future<void> switchCamera() async {
    if (_localStream != null && _localStream!.getVideoTracks().isNotEmpty) {
      final videoTrack = _localStream!.getVideoTracks()[0];
      await Helper.switchCamera(videoTrack);
    }
  }
  
  Future<void> endCall(String roomId, String myId) async {
    for (var entry in _peerConnections.entries) {
      await entry.value.close();
    }
    _peerConnections.clear();
    
    for (var stream in _remoteStreams.values) {
      stream.dispose();
    }
    _remoteStreams.clear();
    
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
    
    for (var subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    
    try {
      await _database.child('webrtc_signaling/$roomId/peers/$myId').remove();
    } catch (e) {
    }
  }
  
  void dispose() {
    for (var subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
    
    _localStreamController.close();
    _remoteStreamsController.close();
    _peerDisconnectController.close();
  }
}

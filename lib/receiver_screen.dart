import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final TextEditingController _roomIdController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  Timer? _candidateTimer;
  Timer? _notificationTimer;
  List<RTCIceCandidate> _pendingRemoteCandidates = [];

  final String _signalingServer = 'http://10.170.0.190:9999/webrtc-signaling-server/api/v1/web';
  // final String _signalingServer = 'http://localhost:9999/webrtc-signaling-server/api/v1/web';
  String _roomId = '';
  String? _incomingRoomId;
  DateTime? _lastNotificationTime;

  bool _isConnected = false;
  bool _isLoading = false;
  bool _isMuted = false;
  bool _isVideoOff = false;
  bool _isFrontCamera = true;
  bool _hasRemoteDescription = false;
  bool _isDisposed = false;
  bool _isRinging = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      await _createPeerConnection();
      _startNotificationListener();

      _roomIdController.addListener(() {
        if (!_isDisposed) {
          setState(() {
            _roomId = _roomIdController.text;
          });
        }
      });
    } catch (e) {
      debugPrint('Initialization error: $e');
      _showError('Initialization failed');
    }
  }

  Future<void> _createPeerConnection() async {
    try {
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ]
      };

      _peerConnection = await createPeerConnection(configuration);

      _peerConnection?.onIceCandidate = (candidate) async {
        if (_isDisposed || _peerConnection == null) return;
        if (candidate.candidate?.isNotEmpty ?? false) {
          try {
            await http.post(
              Uri.parse('$_signalingServer/candidate'),
              body: json.encode({
                'roomId': _roomId,
                'candidate': candidate.toMap(),
                'type': 'receiver'
              }),
              headers: {'Content-Type': 'application/json'},
            );
          } catch (e) {
            debugPrint('Error sending ICE candidate: $e');
          }
        }
      };

      _peerConnection?.onIceConnectionState = (state) {
        debugPrint('ICE connection state: $state');
        if (_isDisposed) return;
        if (mounted) {
          setState(() {
            if (state ==
                    RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
              _disconnect();
            }
          });
        }
      };

      _peerConnection?.onTrack = (event) {
        if (_isDisposed) return;
        if (event.streams.isNotEmpty && mounted) {
          setState(() {
            _remoteStream = event.streams.first;
            _remoteRenderer.srcObject = _remoteStream;
            _isConnected = true;
            _isLoading = false;
          });
        }
      };

      _peerConnection?.onConnectionState = (state) {
        debugPrint('Peer connection state: $state');
      };
    } catch (e) {
      debugPrint('Peer connection creation error: $e');
      _showError('Failed to create connection');
    }
  }

  void _startNotificationListener() {
    _notificationTimer?.cancel();
    _notificationTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_isDisposed || _isConnected) return;

      try {
        final response = await http.get(
          Uri.parse('$_signalingServer/notification'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          final List<dynamic> notifications = json.decode(response.body);
          if (notifications.isNotEmpty) {
            final latestNotification = notifications.last;
            final roomId = latestNotification['roomId']?.toString();
            final notificationTime = DateTime.fromMillisecondsSinceEpoch(
                int.parse(latestNotification['timestamp'].toString()));

            if (roomId != null &&
                roomId.isNotEmpty &&
                (_lastNotificationTime == null ||
                    notificationTime.isAfter(_lastNotificationTime!))) {
              _lastNotificationTime = notificationTime;
              _incomingRoomId = roomId;

              if (mounted && !_isDisposed) {
                setState(() {
                  _isRinging = true;
                });
                await _playRingtone();
                _showIncomingCallDialog();
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Notification error: $e');
      }
    });
  }

  Future<void> _playRingtone() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setSource(AssetSource('sounds/incoming_call.mp3'));
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.resume();
    } catch (e) {
      debugPrint('Ringtone error: $e');
    }
  }

  Future<void> _stopRingtone() async {
    try {
      await _audioPlayer.stop();
      if (mounted && !_isDisposed) {
        setState(() {
          _isRinging = false;
        });
      }
    } catch (e) {
      debugPrint('Stop ringtone error: $e');
    }
  }

  void _showIncomingCallDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Incoming Call'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Room ID: $_incomingRoomId'),
            const SizedBox(height: 10),
            Text(
              'Received: ${DateFormat('HH:mm:ss').format(DateTime.now())}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _handleCallResponse(false),
            child: const Text('Decline', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => _handleCallResponse(true),
            child: const Text('Accept', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCallResponse(bool accept) async {
    try {
      await _stopRingtone();

      if (_incomingRoomId != null) {
        await http.delete(
          Uri.parse('$_signalingServer/notification/$_incomingRoomId'),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (!mounted || _isDisposed) return;

      if (accept && _incomingRoomId != null) {
        setState(() {
          _roomIdController.text = _incomingRoomId!;
          _roomId = _incomingRoomId!;
        });
        _joinRoom();
      }

      Navigator.of(context).pop();
    } catch (e) {
      debugPrint('Call response error: $e');
      if (mounted) {
        _showError('Failed to handle call response');
      }
    }
  }

  Future<void> _joinRoom() async {
    if (_roomId.isEmpty || _isDisposed || _peerConnection == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final mediaConstraints = {
        'audio': true,
        'video': {
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 30},
          'facingMode': _isFrontCamera ? 'user' : 'environment'
        }
      };

      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localRenderer.srcObject = _localStream;

      for (final track in _localStream!.getTracks()) {
        _peerConnection?.addTrack(track, _localStream!);
      }

      _startCandidateTimer();

      final offer = await _waitForOffer();
      if (offer == null) {
        throw Exception('No offer received');
      }

      await _peerConnection?.setRemoteDescription(offer);
      if (!_isDisposed && mounted) {
        setState(() {
          _hasRemoteDescription = true;
        });
      }
      await _processPendingCandidates();

      final answer = await _peerConnection?.createAnswer();
      if (answer == null) {
        throw Exception('Failed to create answer');
      }

      await _peerConnection?.setLocalDescription(answer);

      await http.post(
        Uri.parse('$_signalingServer/answer/$_roomId'),
        body: json.encode({
          'sdp': answer.sdp,
          'type': answer.type,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      debugPrint('Join room error: $e');
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoading = false;
        });
        _showError('Failed to join room');
      }
      _disconnect();
    }
  }

  Future<RTCSessionDescription?> _waitForOffer() async {
    try {
      while (_roomId.isNotEmpty && mounted && !_isConnected && !_isDisposed) {
        final response = await http.get(
          Uri.parse('$_signalingServer/offer/$_roomId'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data is Map && data.isNotEmpty && data['sdp'] != null) {
            return RTCSessionDescription(data['sdp'], data['type']);
          }
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    } catch (e) {
      debugPrint('Wait for offer error: $e');
    }
    return null;
  }

  void _startCandidateTimer() {
    _candidateTimer?.cancel();
    _candidateTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_roomId.isEmpty || _isDisposed) {
        timer.cancel();
        return;
      }
      await _checkForRemoteCandidates();
    });
  }

  Future<void> _checkForRemoteCandidates() async {
    try {
      final response = await http.get(
        Uri.parse('$_signalingServer/candidates/$_roomId/caller'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final List<dynamic> candidates = json.decode(response.body);
        for (final candidate in candidates) {
          final iceCandidate = RTCIceCandidate(
            candidate['candidate'],
            candidate['sdpMid'],
            candidate['sdpMLineIndex'],
          );

          if (_hasRemoteDescription) {
            try {
              await _peerConnection?.addCandidate(iceCandidate);
            } catch (e) {
              debugPrint('Add candidate error: $e');
              if (!_isDisposed) {
                _pendingRemoteCandidates.add(iceCandidate);
              }
            }
          } else if (!_isDisposed) {
            _pendingRemoteCandidates.add(iceCandidate);
          }
        }
      }
    } catch (e) {
      debugPrint('Check candidates error: $e');
    }
  }

  Future<void> _processPendingCandidates() async {
    while (_pendingRemoteCandidates.isNotEmpty) {
      final candidate = _pendingRemoteCandidates.removeAt(0);
      try {
        await _peerConnection?.addCandidate(candidate);
      } catch (e) {
        debugPrint('Process candidate error: $e');
        if (!_isDisposed) {
          _pendingRemoteCandidates.insert(0, candidate);
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }

  Future<void> _disconnect() async {
    try {
      _candidateTimer?.cancel();
      if (_roomId.isNotEmpty && !_isDisposed) {
        await http.post(
          Uri.parse('$_signalingServer/end/$_roomId'),
          headers: {'Content-Type': 'application/json'},
        );
      }

      await _peerConnection?.close();

      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          track.stop();
        }
        _localStream?.dispose();
      }

      if (_remoteStream != null) {
        for (final track in _remoteStream!.getTracks()) {
          track.stop();
        }
        _remoteStream?.dispose();
      }

      if (mounted && !_isDisposed) {
        setState(() {
          _isConnected = false;
          _isLoading = false;
          _roomId = '';
          _hasRemoteDescription = false;
          _pendingRemoteCandidates = [];
          _localStream = null;
          _remoteStream = null;
        });
      }

      await _createPeerConnection();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }

  Future<void> _toggleMute() async {
    if (_localStream == null || _isDisposed) return;

    setState(() {
      _isMuted = !_isMuted;
    });

    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
  }

  Future<void> _toggleVideo() async {
    if (_localStream == null || _isDisposed) return;

    setState(() {
      _isVideoOff = !_isVideoOff;
    });

    for (final track in _localStream!.getVideoTracks()) {
      track.enabled = !_isVideoOff;
    }
  }

  Future<void> _switchCamera() async {
    if (_localStream == null || _isDisposed) return;

    try {
      final videoTrack = _localStream!.getVideoTracks().first;
      await Helper.switchCamera(videoTrack);
      if (mounted && !_isDisposed) {
        setState(() {
          _isFrontCamera = !_isFrontCamera;
        });
      }
    } catch (e) {
      debugPrint('Switch camera error: $e');
      _showError('Failed to switch camera');
    }
  }

  void _showError(String message) {
    if (mounted && !_isDisposed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _candidateTimer?.cancel();
    _notificationTimer?.cancel();
    _audioPlayer.dispose();
    _roomIdController.dispose();
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    _peerConnection?.close();
    _localStream?.dispose();
    _remoteStream?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receiver'),
        actions: [
          if (_isRinging)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Icon(Icons.notifications_active, color: Colors.red),
            ),
          if (_isConnected)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Center(
                child: Text(
                  'Room: ${_roomId.substring(0, 6)}...',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_isConnected)
                    RTCVideoView(_remoteRenderer, mirror: false),
                  if (!_isConnected && _isLoading)
                    const Center(child: CircularProgressIndicator()),
                  if (!_isConnected && !_isLoading)
                    Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                'Enter Room ID to join call',
                                style: TextStyle(fontSize: 18),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: 300,
                                child: TextField(
                                  controller: _roomIdController,
                                  decoration: const InputDecoration(
                                    labelText: 'Room ID',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.meeting_room),
                                  ),
                                  textInputAction: TextInputAction.go,
                                  onSubmitted: (_) => _joinRoom(),
                                ),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                onPressed:
                                    _roomId.isNotEmpty ? _joinRoom : null,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 30, vertical: 15),
                                ),
                                child: const Text('Join Call'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_isConnected || _isLoading)
                    Positioned(
                      right: 20,
                      top: 20,
                      width: 120,
                      height: 180,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: Container(
                          color: Colors.black,
                          child: RTCVideoView(
                            _localRenderer,
                            mirror: _isFrontCamera,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_isConnected)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.call_end),
                      onPressed: _disconnect,
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.all(15),
                      ),
                    ),
                    IconButton(
                      icon: Icon(_isMuted ? Icons.mic_off : Icons.mic),
                      onPressed: _toggleMute,
                      color: _isMuted ? Colors.red : Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        padding: const EdgeInsets.all(15),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                          _isVideoOff ? Icons.videocam_off : Icons.videocam),
                      onPressed: _toggleVideo,
                      color: _isVideoOff ? Colors.red : Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        padding: const EdgeInsets.all(15),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.switch_video),
                      onPressed: _switchCamera,
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        padding: const EdgeInsets.all(15),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}






































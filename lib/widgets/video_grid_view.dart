import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../theme/app_theme.dart';

class VideoGridView extends StatelessWidget {
  final List<VideoParticipant> participants;
  final String? highlightedUserId;

  const VideoGridView({
    super.key,
    required this.participants,
    this.highlightedUserId,
  });

  @override
  Widget build(BuildContext context) {
    final participantCount = participants.length;
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);

    if (participantCount == 0) {
      return Center(
        child: Text(
          'No participants',
          style: TextStyle(color: onSurfaceColor, fontSize: 18),
        ),
      );
    }

    if (participantCount == 1) {
      return _buildVideoTile(context, participants[0], isFullScreen: true);
    }

    if (participantCount == 2) {
      return Column(
        children: [
          Expanded(child: _buildVideoTile(context, participants[0])),
          Expanded(child: _buildVideoTile(context, participants[1])),
        ],
      );
    }

    if (participantCount == 3) {
      return Column(
        children: [
          Expanded(
            flex: 2,
            child: _buildVideoTile(context, participants[0]),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildVideoTile(context, participants[1])),
                Expanded(child: _buildVideoTile(context, participants[2])),
              ],
            ),
          ),
        ],
      );
    }

    if (participantCount == 4) {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildVideoTile(context, participants[0])),
                Expanded(child: _buildVideoTile(context, participants[1])),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildVideoTile(context, participants[2])),
                Expanded(child: _buildVideoTile(context, participants[3])),
              ],
            ),
          ),
        ],
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: participantCount,
      itemBuilder: (context, index) {
        return _buildVideoTile(context, participants[index]);
      },
    );
  }

  Widget _buildVideoTile(BuildContext context, VideoParticipant participant, {bool isFullScreen = false}) {
    final isHighlighted = highlightedUserId != null && 
                          participant.userId == highlightedUserId;
    final primaryColor = AppTheme.getPrimaryColor(context);
    final surfaceColor = AppTheme.getSurfaceColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final overlayColor = AppTheme.getOverlayColor(context);
    final errorColor = AppTheme.getErrorColor(context);

    return Container(
      margin: isFullScreen ? EdgeInsets.zero : const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: isHighlighted
            ? Border.all(color: primaryColor, width: 3)
            : null,
        borderRadius: BorderRadius.circular(isFullScreen ? 0 : 8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(isFullScreen ? 0 : 8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            participant.renderer.srcObject != null
                ? RTCVideoView(
                    participant.renderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    mirror: participant.isMirrored,
                  )
                : Container(
                    color: surfaceColor,
                    child: Center(
                      child: Icon(
                        Icons.person,
                        size: isFullScreen ? 100 : 50,
                        color: onSurfaceColor.withOpacity(0.5),
                      ),
                    ),
                  ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      overlayColor.withOpacity(0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      participant.isMicOn ? Icons.mic : Icons.mic_off,
                      size: 16,
                      color: participant.isMicOn ? onSurfaceColor : errorColor,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        participant.userName,
                        style: TextStyle(
                          color: onSurfaceColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!participant.isCameraOn)
              Container(
                color: overlayColor.withOpacity(0.7),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.videocam_off,
                        size: isFullScreen ? 60 : 40,
                        color: onSurfaceColor.withOpacity(0.7),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        participant.userName,
                        style: TextStyle(
                          color: onSurfaceColor.withOpacity(0.7),
                          fontSize: isFullScreen ? 18 : 14,
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
}

class VideoParticipant {
  final String userId;
  final String userName;
  final RTCVideoRenderer renderer;
  final bool isCameraOn;
  final bool isMicOn;
  final bool isMirrored;

  VideoParticipant({
    required this.userId,
    required this.userName,
    required this.renderer,
    this.isCameraOn = true,
    this.isMicOn = true,
    this.isMirrored = false,
  });
}

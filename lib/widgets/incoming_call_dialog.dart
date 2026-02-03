import 'package:flutter/material.dart';
import '../services/call_request_service.dart';
import '../theme/app_theme.dart';

/// Dialog to show incoming call request
class IncomingCallDialog extends StatefulWidget {
  final CallRequest request;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const IncomingCallDialog({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onReject,
  });

  @override
  State<IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<IncomingCallDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // Get icon and label based on call type
  IconData _getCallTypeIcon() {
    switch (widget.request.callType) {
      case CallType.chat:
        return Icons.chat_rounded;
      case CallType.voice:
        return Icons.phone_rounded;
      case CallType.video:
        return Icons.videocam_rounded;
    }
  }
  
  String _getCallTypeLabel() {
    switch (widget.request.callType) {
      case CallType.chat:
        return 'Chat Request';
      case CallType.voice:
        return 'Voice Call';
      case CallType.video:
        return 'Video Call';
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final secondaryColor = AppTheme.getSecondaryColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final errorColor = AppTheme.getErrorColor(context);
    
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              primaryColor,
              primaryColor.withOpacity(0.8),
            ],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: primaryColor.withOpacity(0.5),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _getCallTypeLabel(),
              style: TextStyle(
                color: AppTheme.getOnPrimaryColor(context),
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),

            ScaleTransition(
              scale: _pulseAnimation,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      secondaryColor,
                      secondaryColor.withOpacity(0.7),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: secondaryColor.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Icon(
                  _getCallTypeIcon(),
                  size: 50,
                  color: AppTheme.getOnPrimaryColor(context),
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text(
              widget.request.callerName,
              style: TextStyle(
                color: AppTheme.getOnPrimaryColor(context),
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),

            Text(
              'ID: ${widget.request.callerId}',
              style: TextStyle(
                color: AppTheme.getOnPrimaryColor(context).withOpacity(0.7),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 32),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildActionButton(
                  icon: Icons.call_end,
                  label: 'Reject',
                  color: errorColor,
                  onPressed: widget.onReject,
                ),

                _buildActionButton(
                  icon: _getCallTypeIcon(),
                  label: 'Accept',
                  color: secondaryColor,
                  onPressed: widget.onAccept,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(35),
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.5),
                    blurRadius: 15,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(
                icon,
                color: AppTheme.getOnPrimaryColor(context),
                size: 32,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: AppTheme.getOnPrimaryColor(context),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

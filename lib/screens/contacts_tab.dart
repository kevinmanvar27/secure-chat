import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'call_screen.dart';
import '../services/user_service.dart';
import '../services/session_manager.dart';
import '../services/call_request_service.dart';
import '../services/ad_service.dart';
import '../widgets/outgoing_call_dialog.dart';
import 'dart:async';

class ContactsTab extends StatefulWidget {
  const ContactsTab({super.key});

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> with AutomaticKeepAliveClientMixin {
  final SessionManager _sessionManager = SessionManager();
  final UserService _userService = UserService();
  final CallRequestService _callRequestService = CallRequestService();
  final AdService _adService = AdService();
  
  String get myUserId => _sessionManager.userId;
  
  List<Contact> _contacts = [];
  List<AppUser> _appUsers = []; // Contacts who have the app
  Set<String> _appUserPhones = {}; // Phone numbers of app users
  
  bool _isLoading = true;
  bool _hasPermission = false;
  String _searchQuery = '';
  
  // Banner Ad
  BannerAd? _bannerAd;
  bool _isBannerAdLoaded = false;
  
  final TextEditingController _searchController = TextEditingController();

  // Play Store link
  static const String playStoreLink = 'https://play.google.com/store/apps/details?id=com.rektech.chatapp';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _loadBannerAd();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _bannerAd?.dispose();
    super.dispose();
  }

  void _loadBannerAd() {
    final bannerAd = _adService.createBannerAd(
      onAdLoaded: () {
        if (mounted) {
          setState(() => _isBannerAdLoaded = true);
        }
      },
      onAdFailedToLoad: (error) {
        if (mounted) {
          setState(() => _isBannerAdLoaded = false);
        }
      },
    );
    
    if (bannerAd != null) {
      _bannerAd = bannerAd;
      _bannerAd!.load();
    }
  }

  Future<void> _loadContacts() async {
    setState(() {
      _isLoading = true;
    });

    // Request contacts permission
    final status = await Permission.contacts.request();
    _hasPermission = status.isGranted;

    if (!_hasPermission) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      // Get device contacts
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: true,
      );

      // Filter contacts with phone numbers
      _contacts = contacts.where((c) => c.phones.isNotEmpty).toList();
      
      // Sort by name
      _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));

      // Get phone numbers
      final phoneNumbers = <String>[];
      for (var contact in _contacts) {
        for (var phone in contact.phones) {
          phoneNumbers.add(phone.number);
        }
      }

      // Check which contacts are app users
      _appUsers = await _userService.findUsersByPhoneHashes(phoneNumbers);
      
      // Create set of app user phone numbers for quick lookup
      _appUserPhones = _appUsers.map((u) => _normalizePhone(u.phoneNumber)).toSet();

      // Save contacts to Firebase for future matching
      final contactsData = _contacts.map((c) => {
        'name': c.displayName,
        'phone': c.phones.isNotEmpty ? c.phones.first.number : '',
      }).toList();
      await _userService.saveUserContacts(myUserId, contactsData);

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _showSnackBar('Failed to load contacts');
    }
  }

  String _normalizePhone(String phone) {
    String normalized = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (normalized.length > 10) {
      normalized = normalized.substring(normalized.length - 10);
    }
    return normalized;
  }

  bool _isAppUser(Contact contact) {
    for (var phone in contact.phones) {
      if (_appUserPhones.contains(_normalizePhone(phone.number))) {
        return true;
      }
    }
    return false;
  }

  AppUser? _getAppUser(Contact contact) {
    for (var phone in contact.phones) {
      final normalized = _normalizePhone(phone.number);
      for (var user in _appUsers) {
        if (_normalizePhone(user.phoneNumber) == normalized) {
          return user;
        }
      }
    }
    return null;
  }

  List<Contact> get _filteredContacts {
    if (_searchQuery.isEmpty) {
      return _contacts;
    }
    return _contacts.where((c) {
      return c.displayName.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
  }

  Future<void> _callUser(AppUser user, String contactName) async {
    // Request permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    if (!statuses[Permission.camera]!.isGranted ||
        !statuses[Permission.microphone]!.isGranted) {
      _showSnackBar('Camera and microphone permissions required');
      return;
    }

    try {
      // Create room
      final roomId = await _callRequestService.createCallRoom(myUserId);
      _sessionManager.currentRoomId = roomId;

      // Send call request
      _sessionManager.currentRequestId = await _callRequestService.sendCallRequest(
        callerId: myUserId,
        callerName: 'User $myUserId',
        receiverId: user.odid,
        roomId: roomId,
      );

      if (mounted) {
        _showOutgoingCallDialog(user.odid, contactName);
      }
    } catch (e) {
      _showSnackBar('Failed to initiate call');
    }
  }

  void _showOutgoingCallDialog(String receiverId, String receiverName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => OutgoingCallDialog(
        receiverName: receiverName,
        receiverId: receiverId,
        onCancel: () {
          if (_sessionManager.currentRequestId != null) {
            _callRequestService.cancelCallRequest(_sessionManager.currentRequestId!);
          }
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
            _joinCall(request.roomId, receiverId);
          } else if (request.status == 'rejected') {
            Navigator.of(context).pop();
            _showSnackBar('Call rejected');
          } else if (request.status == 'cancelled') {
            Navigator.of(context).pop();
          }
        }
      });

      Future.delayed(const Duration(seconds: 60), () {
        statusSubscription.cancel();
      });
    }
  }

  void _joinCall(String roomId, String remoteId) {
    _sessionManager.currentRoomId = roomId;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CallScreen(
          myId: myUserId,
          remoteId: remoteId,
          isCaller: true,
          roomId: roomId,
        ),
      ),
    ).then((result) {
      if (mounted) {
        if (_sessionManager.currentRoomId != null) {
          _callRequestService.leaveCallRoom(_sessionManager.currentRoomId!, myUserId);
        }
        _sessionManager.clearCallSession();
        _showSnackBar('Call ended');
      }
    });
  }

  /// Send user's code to an app user via WhatsApp
  /// Includes direct call link that auto-fills sender's code
  Future<void> _sendCodeToAppUser(Contact contact) async {
    // Check if should show ad for invite
    if (_adService.shouldShowAdForInvite()) {
      await _adService.showInterstitialAd();
    }

    final phone = contact.phones.isNotEmpty ? contact.phones.first.number : '';
    if (phone.isEmpty) {
      _showSnackBar('No phone number available');
      return;
    }

    // Create deep link - custom scheme that opens app directly with code auto-filled
    final directCallLink = 'securechat://call/$myUserId';
    
    final message = '''Hey ${contact.displayName}! Let's video chat on SecureChat.

📞 *Click to call me directly:*
$directCallLink

🆔 *My Code:* $myUserId

📱 *Don't have the app?*
$playStoreLink''';
    
    await _openWhatsAppChat(phone, message);
  }

  /// Invite a non-app user via WhatsApp
  /// Includes direct call link that auto-fills sender's code after download
  Future<void> _inviteContact(Contact contact) async {
    // Check if should show ad for invite
    if (_adService.shouldShowAdForInvite()) {
      await _adService.showInterstitialAd();
    }

    final phone = contact.phones.isNotEmpty ? contact.phones.first.number : '';
    if (phone.isEmpty) {
      _showSnackBar('No phone number available');
      return;
    }

    // Create deep link for after they download the app
    final directCallLink = 'securechat://call/$myUserId';

    final message = '''Hey ${contact.displayName}! Join me on SecureChat for free encrypted video calls.

📱 *Download the app:*
$playStoreLink

📞 *After installing, click to call me:*
$directCallLink

🆔 *My Code:* $myUserId''';
    
    await _openWhatsAppChat(phone, message);
  }

  /// Open WhatsApp chat with a specific phone number and message
  Future<void> _openWhatsAppChat(String phone, String message) async {
    // Clean phone number - remove all non-digit characters except +
    String cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
    
    // Remove leading + if present, WhatsApp expects just digits
    if (cleanPhone.startsWith('+')) {
      cleanPhone = cleanPhone.substring(1);
    }
    
    // If number doesn't have country code (less than 10 digits), assume India (+91)
    if (cleanPhone.length == 10) {
      cleanPhone = '91$cleanPhone';
    }
    
    final encodedMessage = Uri.encodeComponent(message);
    
    // Try multiple methods to open WhatsApp
    final List<Uri> urisToTry = [
      // Method 1: WhatsApp API URL (most reliable)
      Uri.parse('https://api.whatsapp.com/send?phone=$cleanPhone&text=$encodedMessage'),
      // Method 2: wa.me URL
      Uri.parse('https://wa.me/$cleanPhone?text=$encodedMessage'),
      // Method 3: Direct WhatsApp intent
      Uri.parse('whatsapp://send?phone=$cleanPhone&text=$encodedMessage'),
    ];
    
    for (final uri in urisToTry) {
      try {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return;
      } catch (e) {
        // Try next method
        continue;
      }
    }
    
    // If all methods fail, show error
    _showSnackBar('Could not open WhatsApp. Please make sure WhatsApp is installed.');
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.deepPurple.shade700,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Contacts',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _loadContacts,
                        icon: Icon(
                          Icons.refresh,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        tooltip: 'Refresh contacts',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Search bar
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search contacts...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                });
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                ],
              ),
            ),

            // Stats
            if (!_isLoading && _hasPermission)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _buildStatChip(
                      icon: Icons.people,
                      label: '${_contacts.length} contacts',
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    _buildStatChip(
                      icon: Icons.check_circle,
                      label: '${_appUsers.length} on app',
                      color: Colors.green,
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            // Content
            Expanded(
              child: _buildContent(),
            ),
            
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
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (!_hasPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.contacts,
                size: 80,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              ),
              const SizedBox(height: 24),
              Text(
                'Contacts Permission Required',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'We need access to your contacts to show you which friends are using SecureChat.',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadContacts,
                icon: const Icon(Icons.lock_open),
                label: const Text('Grant Permission'),
              ),
            ],
          ),
        ),
      );
    }

    if (_contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person_off,
              size: 80,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No contacts found',
              style: TextStyle(
                fontSize: 18,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    }

    final filteredContacts = _filteredContacts;

    if (filteredContacts.isEmpty) {
      return Center(
        child: Text(
          'No contacts match "$_searchQuery"',
          style: TextStyle(
            fontSize: 16,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
      );
    }

    // Separate app users and non-app users
    final appUserContacts = filteredContacts.where((c) => _isAppUser(c)).toList();
    final nonAppUserContacts = filteredContacts.where((c) => !_isAppUser(c)).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        // App users section
        if (appUserContacts.isNotEmpty) ...[
          _buildSectionHeader('On SecureChat', Icons.check_circle, Colors.green),
          ...appUserContacts.map((contact) => _buildContactTile(contact, isAppUser: true)),
          const SizedBox(height: 16),
        ],

        // Non-app users section
        if (nonAppUserContacts.isNotEmpty) ...[
          _buildSectionHeader('Invite to SecureChat', Icons.person_add, Colors.orange),
          ...nonAppUserContacts.map((contact) => _buildContactTile(contact, isAppUser: false)),
        ],

        const SizedBox(height: 100),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(Contact contact, {required bool isAppUser}) {
    final appUser = isAppUser ? _getAppUser(contact) : null;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          children: [
            // Avatar
            CircleAvatar(
              radius: 24,
              backgroundColor: isAppUser 
                  ? Colors.green.withOpacity(0.2) 
                  : Theme.of(context).colorScheme.primaryContainer,
              backgroundImage: contact.photo != null 
                  ? MemoryImage(contact.photo!) 
                  : null,
              child: contact.photo == null
                  ? Text(
                      contact.displayName.isNotEmpty 
                          ? contact.displayName[0].toUpperCase() 
                          : '?',
                      style: TextStyle(
                        color: isAppUser 
                            ? Colors.green 
                            : Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    )
                  : null,
            ),
            
            const SizedBox(width: 12),
            
            // Name and phone
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    contact.phones.isNotEmpty ? contact.phones.first.number : 'No phone',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
            
            // Action buttons
            if (isAppUser) ...[
              // Send Code button (WhatsApp)
              IconButton(
                onPressed: () => _sendCodeToAppUser(contact),
                icon: Icon(
                  Icons.share,
                  color: Colors.green.shade600,
                  size: 22,
                ),
                tooltip: 'Send Code via WhatsApp',
              ),
              const SizedBox(width: 4),
              // Call button
              ElevatedButton.icon(
                onPressed: () {
                  if (appUser != null) {
                    _callUser(appUser, contact.displayName);
                  }
                },
                icon: const Icon(Icons.video_call, size: 18),
                label: const Text('Call'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 36),
                ),
              ),
            ] else ...[
              // Invite button (WhatsApp)
              ElevatedButton.icon(
                onPressed: () => _inviteContact(contact),
                icon: const Icon(Icons.chat, size: 16), // WhatsApp-like icon
                label: const Text('Invite'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 36),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

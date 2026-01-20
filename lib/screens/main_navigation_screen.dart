import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'home_tab.dart';
import 'random_tab.dart';
import 'contacts_tab.dart';
import '../services/user_service.dart';
import '../services/session_manager.dart';
import '../services/ad_service.dart';

class MainNavigationScreen extends StatefulWidget {
  final String? initialRemoteId; // For deep link handling
  
  const MainNavigationScreen({super.key, this.initialRemoteId});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;  // 0 = Random (now first tab)
  int _previousIndex = 0;
  final AdService _adService = AdService();
  int _tabSwitchCount = 0;
  
  // Keys to access tab states
  final GlobalKey<RandomTabState> _randomTabKey = GlobalKey<RandomTabState>();
  
  // Lazy loading - track which tabs have been visited
  final Set<int> _loadedTabs = {0}; // Random tab loaded by default (index 0)
  
  // Tab widgets - created lazily
  Widget? _randomTab;  // Index 0
  Widget? _homeTab;    // Index 1
  Widget? _contactsTab; // Index 2

  @override
  void initState() {
    super.initState();
    // Create random tab initially (it's the default now)
    _randomTab = RandomTab(key: _randomTabKey);
    // Auto-start random tab camera on app launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _randomTabKey.currentState?.onTabActive();
    });
  }

  @override
  void dispose() {
    // Clean up when leaving
    UserService().leaveRandomPool(SessionManager().userId);
    super.dispose();
  }
  
  /// Get or create tab widget lazily
  Widget _getTab(int index) {
    switch (index) {
      case 0:
        _randomTab ??= RandomTab(key: _randomTabKey);
        return _randomTab!;
      case 1:
        _homeTab ??= HomeTab(initialRemoteId: widget.initialRemoteId);
        return _homeTab!;
      case 2:
        _contactsTab ??= const ContactsTab();
        return _contactsTab!;
      default:
        return const SizedBox();
    }
  }

  void _onTabChanged(int index) async {
    // If leaving random tab (index 0), check if we need confirmation
    if (_currentIndex == 0 && index != 0) {
      // Leaving random tab - check if in call
      final canSwitch = await _randomTabKey.currentState?.onTabInactive() ?? true;
      if (!canSwitch) {
        // User cancelled, don't switch tab
        return;
      }
    }
    
    _previousIndex = _currentIndex;
    
    // Show interstitial ad every 3 tab switches (not for random tab - it has its own logic)
    _tabSwitchCount++;
    if (_tabSwitchCount % 3 == 0 && index != 0) {
      await _adService.showInterstitialAd();
    }
    
    // Mark tab as loaded
    _loadedTabs.add(index);
    
    setState(() {
      _currentIndex = index;
    });
    
    if (index == 0 && _previousIndex != 0) {
      // Entering random tab - start camera
      // Small delay to ensure widget is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _randomTabKey.currentState?.onTabActive();
      });
    }
    
    // Leave random pool when not on random tab
    if (index != 0) {
      UserService().leaveRandomPool(SessionManager().userId);
    }
  }

  Future<void> _launchRektechUrl() async {
    final Uri url = Uri.parse('https://rektech.uk/');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      print('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          // Tab order: Random (0), Home (1), Contacts (2)
          _loadedTabs.contains(0) ? _getTab(0) : const SizedBox(),
          _loadedTabs.contains(1) ? _getTab(1) : const SizedBox(),
          _loadedTabs.contains(2) ? _getTab(2) : const SizedBox(),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: _onTabChanged,
              type: BottomNavigationBarType.fixed,
              selectedItemColor: Theme.of(context).colorScheme.primary,
              unselectedItemColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              items: const [
                // Reordered: Random first, then Home, then Contacts
                BottomNavigationBarItem(
                  icon: Icon(Icons.shuffle_rounded),
                  activeIcon: Icon(Icons.shuffle_rounded),
                  label: 'Random',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.home_rounded),
                  activeIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.contacts_rounded),
                  activeIcon: Icon(Icons.contacts_rounded),
                  label: 'Contacts',
                ),
              ],
            ),
          ),
          // Footer - Designed and Developed by Rektech
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(bottom: 20),
            color: Theme.of(context).scaffoldBackgroundColor,
            child: GestureDetector(
              onTap: _launchRektechUrl,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Designed and Developed by ',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                  Text(
                    'Rektech',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.underline,
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
}

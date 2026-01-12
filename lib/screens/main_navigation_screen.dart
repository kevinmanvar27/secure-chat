import 'package:flutter/material.dart';
import 'home_tab.dart';
import 'random_tab.dart';
import 'contacts_tab.dart';
import '../services/user_service.dart';
import '../services/session_manager.dart';

class MainNavigationScreen extends StatefulWidget {
  final String? initialRemoteId; // For deep link handling
  
  const MainNavigationScreen({super.key, this.initialRemoteId});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  int _previousIndex = 0;
  
  // Keys to access tab states
  final GlobalKey<RandomTabState> _randomTabKey = GlobalKey<RandomTabState>();
  
  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = [
      HomeTab(initialRemoteId: widget.initialRemoteId),
      RandomTab(key: _randomTabKey),
      const ContactsTab(),
    ];
  }

  @override
  void dispose() {
    // Clean up when leaving
    UserService().leaveRandomPool(SessionManager().userId);
    super.dispose();
  }

  void _onTabChanged(int index) async {
    // If leaving random tab, check if we need confirmation
    if (_currentIndex == 1 && index != 1) {
      // Leaving random tab - check if in call
      final canSwitch = await _randomTabKey.currentState?.onTabInactive() ?? true;
      if (!canSwitch) {
        // User cancelled, don't switch tab
        return;
      }
    }
    
    _previousIndex = _currentIndex;
    
    setState(() {
      _currentIndex = index;
    });
    
    if (index == 1 && _previousIndex != 1) {
      // Entering random tab - start camera
      _randomTabKey.currentState?.onTabActive();
    }
    
    // Leave random pool when not on random tab
    if (index != 1) {
      UserService().leaveRandomPool(SessionManager().userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: Container(
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
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              activeIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.shuffle_rounded),
              activeIcon: Icon(Icons.shuffle_rounded),
              label: 'Random',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.contacts_rounded),
              activeIcon: Icon(Icons.contacts_rounded),
              label: 'Contacts',
            ),
          ],
        ),
      ),
    );
  }
}

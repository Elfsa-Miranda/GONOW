import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';

class CustomBottomBar extends StatelessWidget {
  const CustomBottomBar({
    required this.currentIndex,
    required this.onDestinationSelected,
    super.key,
  });

  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      shape: const CircularNotchedRectangle(),
      notchMargin: 10,
      height: 78,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _BottomBarItem(
              label: '发现',
              selected: currentIndex == 0,
              selectedIcon: Icons.explore,
              unselectedIcon: Icons.explore_outlined,
              onTap: () => onDestinationSelected(0),
            ),
          ),
          Expanded(
            child: _BottomBarItem(
              label: '行程',
              selected: currentIndex == 1,
              selectedIcon: Icons.map,
              unselectedIcon: Icons.map_outlined,
              onTap: () => onDestinationSelected(1),
            ),
          ),
          const SizedBox(width: 72),
          Expanded(
            child: _BottomBarItem(
              label: '手账',
              selected: currentIndex == 2,
              selectedIcon: Icons.menu_book_rounded,
              unselectedIcon: Icons.photo_album_outlined,
              onTap: () => onDestinationSelected(2),
            ),
          ),
          Expanded(
            child: _BottomBarItem(
              label: '我的',
              selected: currentIndex == 3,
              selectedIcon: Icons.person,
              unselectedIcon: Icons.person_outline,
              onTap: () => onDestinationSelected(3),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBarItem extends StatelessWidget {
  const _BottomBarItem({
    required this.label,
    required this.selected,
    required this.selectedIcon,
    required this.unselectedIcon,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final IconData selectedIcon;
  final IconData unselectedIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? AppColors.primary : AppColors.textSecondary;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              selected ? selectedIcon : unselectedIcon,
              color: color,
              size: selected ? 28 : 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

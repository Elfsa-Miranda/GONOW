import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';

class CustomFab extends StatelessWidget {
  const CustomFab({
    required this.onPressed,
    super.key,
  });

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: AppColors.fabGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: SizedBox(
        width: 72,
        height: 72,
        child: FloatingActionButton(
          onPressed: onPressed,
          shape: const CircleBorder(),
          child: const Icon(
            Icons.auto_awesome,
            color: AppColors.onPrimary,
            size: 32,
          ),
        ),
      ),
    );
  }
}

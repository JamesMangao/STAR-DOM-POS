import 'package:flutter/material.dart';

import 'tokens.dart';

/// Dev-only token gallery — view design tokens on device. Not part of the
/// production navigation; reach it from Settings → View Tokens.
class Gallery extends StatelessWidget {
  const Gallery({super.key});

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token Gallery'),
        backgroundColor: AppColors.card,
        foregroundColor: AppColors.ink,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.screen),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('Colors', [
              _swatch(AppColors.primary, 'primary'),
              _swatch(AppColors.primaryHi, 'primary-hi'),
              _swatch(AppColors.onPrimary, 'on-primary'),
              _swatch(AppColors.yellow, 'yellow'),
              _swatch(AppColors.yellowSoft, 'yellow-soft'),
              _swatch(AppColors.onYellow, 'on-yellow'),
              _swatch(AppColors.lineYellow, 'line-yellow'),
              _swatch(AppColors.green, 'green'),
              _swatch(AppColors.tertiary, 'tertiary'),
              _swatch(AppColors.tertiaryFixed, 'tertiary-fixed'),
              _swatch(AppColors.outline, 'outline'),
            ]),
            _section('Radii', [
              _radiusTile(AppRadius.s, 'r-s'),
              _radiusTile(AppRadius.m, 'r-m'),
              _radiusTile(AppRadius.l, 'r-l'),
              _radiusTile(AppRadius.xl, 'r-xl'),
              _radiusTile(AppRadius.pill, 'pill'),
            ]),
            _section('Spacing', [
              _textTile('screen', '${AppSpacing.screen}'),
              _textTile('bottom-nav', '${AppSpacing.bottomNav}'),
              _textTile('tap-target', '${AppSpacing.tapTarget}'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Sora',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.l),
              border: Border.all(color: AppColors.line),
            ),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  Widget _swatch(Color c, String name) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 24,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.line),
            ),
          ),
          Text(name, style: const TextStyle(fontFamily: 'Sora', fontSize: 13)),
          const SizedBox(width: 8),
          Text(
            '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 11,
              color: AppColors.inkSoft,
            ),
          ),
        ],
      ),
    );
  }

  Widget _radiusTile(double radius, String name) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 28,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceMid,
              borderRadius: BorderRadius.circular(radius.clamp(0, 14)),
              border: Border.all(color: AppColors.line),
            ),
          ),
          Text(name, style: const TextStyle(fontFamily: 'Sora', fontSize: 13)),
          const SizedBox(width: 8),
          Text(
            '${radius}px',
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 11,
              color: AppColors.inkSoft,
            ),
          ),
        ],
      ),
    );
  }

  Widget _textTile(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Sora',
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          Text(
            desc,
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 11,
              color: AppColors.inkSoft,
            ),
          ),
        ],
      ),
    );
  }
}

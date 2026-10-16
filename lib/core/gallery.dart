import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

class Gallery extends StatelessWidget {
  const Gallery({super.key});

  @override
  Widget build(BuildContext ctx) {
    final padding = AppSpacing.screen;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token Gallery'),
        backgroundColor: AppColors.card,
        foregroundColor: AppColors.ink,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(padding),
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
            _section('Elevations & Stamp', [
              _textTile('sh1', AppShadows.sh1.map((s) => s).join('; ')),
              _textTile('sh2', AppShadows.sh2.map((s) => s).join('; ')),
              _textTile('stamp', '2px 2px 0 var(--ink)'),
              _textTile(
                'focus-ring',
                AppShadows.focusRing.map((s) => s).join('; '),
              ),
            ]),
            _section('Radii', [
              _swatchRadius(AppRadius.s, 'r-s'),
              _swatchRadius(AppRadius.m, 'r-m'),
              _swatchRadius(AppRadius.l, 'r-l'),
              _swatchRadius(AppRadius.xl, 'r-xl'),
              _swatchRadius(AppRadius.pill, 'pill'),
            ]),
            _section('Spacing', [
              _textTile('padding', AppSpacing.screen.toString()),
              _textTile('bottom-nav', AppSpacing.bottomNav.toString()),
              _textTile('tap-target', AppSpacing.tapTarget.toString()),
            ]),
            _section('Text & Typography', [
              _textTile(
                'display-large',
                AppTheme.light().textTheme.displayLarge.toString(),
              ),
              _textTile(
                'body-large',
                AppTheme.light().textTheme.bodyLarge.toString(),
              ),
            ]),
            _section('Border & Ink', [
              _textTile('card', 'rgba(255,255,255,1), 1px ${AppColors.line})'),
              _swatch(AppColors.primary, 'button-primary'),
              _swatch(AppColors.yellow, 'button-secondary'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
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
            border: Border.all(color: AppColors.line, width: 1),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _swatch(Color c, String name) {
    return _textTile(
      name,
      'Container(width: 100, height: 30, color: Color(${c.toARGB32()}), margin: const EdgeInsets.all(2))',
    );
  }

  Widget _swatchRadius(num radius, String name) {
    return _textTile(
      name,
      'Container(width: 100, height: 30, borderRadius: BorderRadius.all(Radius.circular($radius)), color: Colors.white)',
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
            '→ $desc',
            style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11),
          ),
        ],
      ),
    );
  }
}

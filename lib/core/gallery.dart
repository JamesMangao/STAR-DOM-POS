import 'package:flutter/material.dart';
import 'package:stardom_pos/theme.dart';
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
            _Section('Colors', [
              _Swatch(AppColors.primary, 'primary'),
              _Swatch(AppColors.primaryHi, 'primary-hi'),
              _Swatch(AppColors.onPrimary, 'on-primary'),
              _Swatch(AppColors.yellow, 'yellow'),
              _Swatch(AppColors.yellowSoft, 'yellow-soft'),
              _Swatch(AppColors.onYellow, 'on-yellow'),
              _Swatch(AppColors.lineYellow, 'line-yellow'),
              _Swatch(AppColors.green, 'green'),
              _Swatch(AppColors.tertiary, 'tertiary'),
              _Swatch(AppColors.tertiaryFixed, 'tertiary-fixed'),
              _Swatch(AppColors.outline, 'outline'),
            ]),
            _Section('Elevations & Stamp', [
              _TextTile('sh1', AppShadows.sh1.map((s) => s).join('; ')),
              _TextTile('sh2', AppShadows.sh2.map((s) => s).join('; ')),
              _TextTile('stamp', '2px 2px 0 var(--ink)'),
              _TextTile('focus-ring', AppShadows.focusRing.map((s) => s).join('; ')),
            ]),
            _Section('Radii', [
              _SwatchRadius(AppRadius.s, 'r-s'),
              _SwatchRadius(AppRadius.m, 'r-m'),
              _SwatchRadius(AppRadius.l, 'r-l'),
              _SwatchRadius(AppRadius.xl, 'r-xl'),
              _SwatchRadius(AppRadius.pill, 'pill'),
            ]),
            _Section('Spacing', [
              _TextTile('padding', AppSpacing.screen.toString()),
              _TextTile('bottom-nav', AppSpacing.bottomNav.toString()),
              _TextTile('tap-target', AppSpacing.tapTarget.toString()),
            ]),
            _Section('Text & Typography', [
              _TextTile(
                  'display-large', AppTheme.light().textTheme.displayLarge.toString()),
              _TextTile('body-large', AppTheme.light().textTheme.bodyLarge.toString()),
            ]),
            _Section('Border & Ink', [
              _TextTile('card', 'rgba(255,255,255,1), 1px ${AppColors.line})'),
              _Swatch(AppColors.primary, 'button-primary'),
              _Swatch(AppColors.yellow, 'button-secondary'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _Section(String title, Widget body) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Text(title,
            style: const TextStyle(
                fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 16)),
      ),
      Container(
        width: double.infinity,
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: AppRadius.rl.toBorder,
            border: Border.all(color: AppColors.line, width: 1)),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: body,
      ),
    ]);
  }

  Widget _Swatch(Color c, String name) {
    return _TextTile(name, 'Container(width: 100, height: 30, color: Color(${
      c.value}), margin: const EdgeInsets.all(2))');
  }

  Widget _SwatchRadius(num radius, String name) {
    return _TextTile(name,
        'Container(width: 100, height: 30, borderRadius: BorderRadius.all(Radius.circular($radius)), color: Colors.white)');
  }

  Widget _TextTile(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 13))),
          Text(
              '→ $desc',
              style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11)),
        ],
      ),
    );
  }
}
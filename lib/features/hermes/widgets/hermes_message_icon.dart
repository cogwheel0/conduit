import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Uses the same Codicon glyphs as Hermes desktop's Bot Mode controls.
abstract final class HermesMessageIcons {
  static const font = 'HermesControls';
  static const add = IconData(0xea60, fontFamily: font);
  static const close = IconData(0xea76, fontFamily: font);
  static const bots = IconData(0xeb08, fontFamily: font);
  static const groups = IconData(0xea7e, fontFamily: font);
  static const filter = IconData(0xeb83, fontFamily: font);
  static const messages = IconData(0xea6b, fontFamily: font);
  static const file = IconData(0xea7b, fontFamily: font);
  static const routines = IconData(0xea82, fontFamily: font);
  static const settings = IconData(0xeb51, fontFamily: font);
  static const back = IconData(0xea9b, fontFamily: font);
  static const next = IconData(0xeab6, fontFamily: font);
  static const send = IconData(0xec0f, fontFamily: font);
  static const check = IconData(0xeab2, fontFamily: font);
  static const tasks = IconData(0xeb67, fontFamily: font);
  static const folder = IconData(0xea83, fontFamily: font);
  static const compass = IconData(0xebd5, fontFamily: font);
  static const edit = IconData(0xea73, fontFamily: font);
  static const menu = IconData(0xeb94, fontFamily: font);
  static const more = IconData(0xea7c, fontFamily: font);
}

class HermesSearchIcon extends StatelessWidget {
  const HermesSearchIcon({super.key, this.size = 20});
  final double size;
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/hermes-search.svg',
    width: size,
    height: size,
    excludeFromSemantics: true,
    colorFilter: ColorFilter.mode(
      IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface,
      BlendMode.srcIn,
    ),
  );
}

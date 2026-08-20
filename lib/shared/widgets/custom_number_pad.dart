import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

class CustomNumberPad extends StatelessWidget {
  const CustomNumberPad({
    required this.onNumberTap,
    required this.onBackspace,
    super.key,
  });

  final void Function(String) onNumberTap;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildRow(['1', '2', '3']),
        const SizedBox(height: 20),
        _buildRow(['4', '5', '6']),
        const SizedBox(height: 20),
        _buildRow(['7', '8', '9']),
        const SizedBox(height: 20),
        _buildRow(['', '0', 'backspace']),
      ],
    );
  }

  Widget _buildRow(List<String> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: keys.map((key) {
        if (key.isEmpty) return const SizedBox(width: 92, height: 72);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: _NumberPadKey(
            keyValue: key,
            onTap: key == 'backspace' ? onBackspace : () => onNumberTap(key),
          ),
        );
      }).toList(),
    );
  }
}

class _NumberPadKey extends StatefulWidget {
  const _NumberPadKey({required this.keyValue, required this.onTap});

  final String keyValue;
  final VoidCallback onTap;

  @override
  State<_NumberPadKey> createState() => _NumberPadKeyState();
}

class _NumberPadKeyState extends State<_NumberPadKey>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.92,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _controller.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _controller.reverse();
    HapticFeedback.lightImpact();
    widget.onTap();
  }

  void _onTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isBackspace = widget.keyValue == 'backspace';
    // Dark mode: match the indicator-dot shade instead of a stark white circle.
    final keyColor = isBackspace
        ? Colors.transparent
        : Theme.of(context).brightness == Brightness.dark
        ? context.mallowColors.dividerLight
        : Colors.white;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: keyColor,
              ),
              child: Center(child: child),
            ),
          );
        },
        child: isBackspace
            ? SvgPicture.asset(
                'assets/icons/backspace.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  context.mallowColors.textPrimary,
                  BlendMode.srcIn,
                ),
              )
            : Text(
                widget.keyValue,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w400,
                  color: context.mallowColors.textPrimary,
                ),
              ),
      ),
    );
  }
}

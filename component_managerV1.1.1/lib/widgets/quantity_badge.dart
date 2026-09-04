import 'package:flutter/material.dart';

/// 数量角标：绿色显示数量；数量 ≤ 0 时置灰并追加「缺货」。
class QuantityBadge extends StatelessWidget {
  final int quantity;

  const QuantityBadge({super.key, required this.quantity});

  @override
  Widget build(BuildContext context) {
    final out = quantity <= 0;
    final Color color = out ? Colors.grey : Colors.green.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            out ? Icons.error_outline : Icons.inventory_2_outlined,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$quantity',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          if (out) ...[
            const SizedBox(width: 3),
            const Text('缺货', style: TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

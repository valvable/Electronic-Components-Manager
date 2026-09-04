import 'package:flutter/material.dart';

import '../core/sync/sync_codec.dart';
import '../models/component.dart';

/// 冲突条目：本机/远端版本并排对比 + 三个裁决按钮。
/// [onResolve] 传 'local' | 'remote' | 'both'。
class ConflictTile extends StatelessWidget {
  final SyncConflict conflict;
  final bool busy;
  final ValueChanged<String> onResolve;

  const ConflictTile({
    super.key,
    required this.conflict,
    required this.busy,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    final c = conflict;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.orange, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${c.local.model}  (${c.cid})',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _Side(label: '本机', component: c.local)),
                const SizedBox(width: 8),
                Expanded(child: _Side(label: '远端', component: c.remote)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _ChoiceButton(
                    label: '保留本地', onTap: busy ? null : () => onResolve('local')),
                _ChoiceButton(
                    label: '保留远端', onTap: busy ? null : () => onResolve('remote')),
                _ChoiceButton(
                    label: '保留两者', onTap: busy ? null : () => onResolve('both')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Side extends StatelessWidget {
  final String label;
  final Component component;

  const _Side({required this.label, required this.component});

  @override
  Widget build(BuildContext context) {
    final c = component;
    final Widget body;
    if (c.isDeleted) {
      body = const Text('已删除',
          style: TextStyle(color: Colors.red, fontSize: 12));
    } else {
      final parts = <String>['库存 ${c.quantity}'];
      if (c.location?.isNotEmpty == true) parts.add('位置 ${c.location}');
      if (c.note?.isNotEmpty == true) parts.add('备注 ${c.note}');
      body = Text(
        parts.join(' · '),
        style: const TextStyle(fontSize: 12),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: label == '本机' ? Colors.blue.shade50 : Colors.purple.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Colors.grey.shade700)),
          const SizedBox(height: 4),
          body,
          const SizedBox(height: 2),
          Text('更新 ${_fmtTs(c.updatedAt)}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  String _fmtTs(int epochSec) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _ChoiceButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _ChoiceButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

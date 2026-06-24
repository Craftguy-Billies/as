import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

/// Free-text branch input with inline expandable suggestion list.
/// The list lives in the normal widget tree (not an overlay), so
/// Consumer<ChatProvider> rebuilds reliably when branches arrive.
class BranchPopup extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  final double width;
  final double height;
  final double borderRadius;

  const BranchPopup({
    super.key,
    required this.controller,
    required this.onChanged,
    this.width = 90,
    this.height = 30,
    this.borderRadius = 8,
  });

  @override
  State<BranchPopup> createState() => _BranchPopupState();
}

class _BranchPopupState extends State<BranchPopup> {
  bool _expanded = false;

  void _select(String branch) {
    widget.controller.text = branch;
    widget.onChanged();
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _expanded ? 140 : widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The text field + toggle button row
          Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(widget.borderRadius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    onChanged: (_) => widget.onChanged(),
                    decoration: InputDecoration(
                      hintText: 'main',
                      hintStyle: TextStyle(color: Colors.grey[700], fontSize: 11),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.only(
                          left: widget.borderRadius > 8 ? 8 : 6, bottom: 2),
                      isDense: true,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: SizedBox(
                    width: widget.height - 2,
                    height: widget.height - 2,
                    child: Icon(
                      _expanded ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      color: Colors.white54,
                      size: widget.height > 30 ? 22 : 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Inline expandable list — always in widget tree, Consumer works
          if (_expanded)
            Consumer<ChatProvider>(
              builder: (_, prov, __) {
                final branches = prov.branches;
                final typed = widget.controller.text.trim();
                final filtered = branches.isEmpty
                    ? <String>[]
                    : branches
                        .where((b) =>
                            typed.isEmpty ||
                            b.toLowerCase().contains(typed.toLowerCase()))
                        .toList();

                final items = <Widget>[];
                if (branches.isEmpty &&
                    !prov.branchesAttempted &&
                    prov.serverRepo.isNotEmpty) {
                  items.add(const _Hint('Loading…'));
                } else if (filtered.isEmpty &&
                    prov.serverRepo.isNotEmpty) {
                  items.add(const _Hint('No branches found'));
                } else if (filtered.isEmpty) {
                  items.add(const _Hint('Type a branch name'));
                } else {
                  for (final b in filtered) {
                    items.add(_BranchTile(b, onTap: () => _select(b)));
                  }
                }
                if (typed.isNotEmpty && !filtered.contains(typed)) {
                  items.add(_BranchTile('Use "$typed"',
                      color: Colors.blueAccent, onTap: () => _select(typed)));
                }

                return Container(
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black54,
                          blurRadius: 6,
                          offset: Offset(0, 3)),
                    ],
                  ),
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: items),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _BranchTile extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback onTap;
  const _BranchTile(this.label, {this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(label,
            style: TextStyle(
                color: color ?? Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w400)),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Text(text,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
    );
  }
}

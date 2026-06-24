import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

/// Free-text branch input with an overlay popup (not inline expand).
/// The popup is anchored below the text field and does NOT push the
/// navbar down. Branches are fetched on open so the list is always fresh.
class BranchPopup extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  final double width;
  final double height;
  final double borderRadius;
  /// The repo whose branches to show. When null, uses ChatProvider.serverRepo.
  /// Pass the repo from the text field so branches match what the user typed.
  final String? repo;

  const BranchPopup({
    super.key,
    required this.controller,
    required this.onChanged,
    this.width = 100,
    this.height = 30,
    this.borderRadius = 8,
    this.repo,
  });

  @override
  State<BranchPopup> createState() => _BranchPopupState();
}

class _BranchPopupState extends State<BranchPopup> {
  final _fieldKey = GlobalKey();
  bool _loading = false;

  Future<void> _openPopup() async {
    // Fetch branches from the repo in the text field (not serverRepo).
    // We pass the repo so the provider fetches for THIS repo, not the last
    // conversation repo.
    final prov = context.read<ChatProvider>();
    final repo = widget.repo?.trim() ?? prov.serverRepo;
    if (repo.isEmpty) return;

    setState(() => _loading = true);
    await prov.fetchBranches(repo: repo);
    if (!mounted) return;
    setState(() => _loading = false);

    // Find position for the overlay popup
    final renderBox = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    // Build popup items from provider's branch list
    final branches = prov.branches;
    final typed = widget.controller.text.trim();
    final filtered = branches
        .where((b) => typed.isEmpty || b.toLowerCase().contains(typed.toLowerCase()))
        .toList();

    final menuItems = <PopupMenuEntry<String>>[];

    if (branches.isEmpty && !prov.branchesAttempted && repo.isNotEmpty) {
      menuItems.add(const PopupMenuItem<String>(
        enabled: false,
        height: 36,
        child: Text('Loading…', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ));
    } else if (filtered.isEmpty && repo.isNotEmpty) {
      menuItems.add(PopupMenuItem<String>(
        enabled: false,
        height: 36,
        child: Text(
          typed.isEmpty ? 'No branches found' : 'No branches matching "$typed"',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ));
    } else {
      for (final b in filtered) {
        menuItems.add(PopupMenuItem<String>(
          value: b,
          height: 36,
          child: Text(b, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ));
      }
    }
    // "Use typed" option when typed text doesn't match any branch
    if (typed.isNotEmpty && !filtered.contains(typed)) {
      menuItems.add(const PopupMenuDivider(height: 1));
      menuItems.add(PopupMenuItem<String>(
        value: typed,
        height: 36,
        child: Text('Use "$typed"',
            style: const TextStyle(color: Colors.blueAccent, fontSize: 12)),
      ));
    }

    if (menuItems.isEmpty) return;

    if (!mounted) return;
    // Popup width: at least 140px. Expands right if space allows, otherwise
    // extends left from the field's right edge.
    final popupWidth = (size.width < 140) ? 140.0 : size.width;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx + size.width - popupWidth,  // right-align with field
        offset.dy + size.height + 2,
        offset.dx + size.width,
        offset.dy + size.height + 2,
      ),
      items: menuItems,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: const Color(0xFF1A1A2E),
    );

    if (selected != null && mounted) {
      widget.controller.text = selected;
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: Container(
        key: _fieldKey,
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
              onTap: _loading ? null : _openPopup,
              child: SizedBox(
                width: widget.height - 2,
                height: widget.height - 2,
                child: _loading
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white54,
                        ),
                      )
                    : const Icon(
                        Icons.arrow_drop_down,
                        color: Colors.white54,
                        size: 20,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

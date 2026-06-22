import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

/// Free-text branch input + ▼ overlay that updates live as branches load.
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
  final _layerLink = LayerLink();
  OverlayEntry? _overlay;
  bool _open = false;

  void _toggle() {
    if (_open) {
      _overlay?.remove();
      _overlay = null;
      _open = false;
    } else {
      _open = true;
      _showOverlay();
    }
  }

  void _showOverlay() {
    _overlay = OverlayEntry(
      builder: (ctx) => Consumer<ChatProvider>(
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

          List<Widget> items;
          if (branches.isEmpty &&
              !prov.branchesAttempted &&
              prov.serverRepo.isNotEmpty) {
            items = [
              const Padding(
                padding: EdgeInsets.all(10),
                child: Text('Loading…',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              )
            ];
          } else if (filtered.isEmpty && prov.serverRepo.isNotEmpty) {
            items = [
              const Padding(
                padding: EdgeInsets.all(10),
                child: Text('No branches found',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              )
            ];
          } else if (filtered.isEmpty) {
            items = [
              const Padding(
                padding: EdgeInsets.all(10),
                child: Text('Type a branch name',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              )
            ];
          } else {
            items = filtered
                .map((b) => GestureDetector(
                      onTap: () {
                        widget.controller.text = b;
                        widget.onChanged();
                        _close();
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        child: Text(b,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ),
                    ))
                .toList();
          }
          if (typed.isNotEmpty && !filtered.contains(typed)) {
            items.add(GestureDetector(
              onTap: () {
                widget.controller.text = typed;
                widget.onChanged();
                _close();
              },
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Text('Use "$typed"',
                    style: const TextStyle(
                        color: Colors.blueAccent, fontSize: 12)),
              ),
            ));
          }

          return Stack(
            children: [
              Positioned(
                width: 140,
                child: CompositedTransformFollower(
                  link: _layerLink,
                  offset: Offset(0, widget.height),
                  showWhenUnlinked: false,
                  child: Material(
                    elevation: 8,
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: items,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    Overlay.of(context).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    _open = false;
    setState(() {});
  }

  @override
  void dispose() {
    _overlay?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        width: widget.width,
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
              onTap: _toggle,
              child: SizedBox(
                width: widget.height - 2,
                height: widget.height - 2,
                child: Icon(Icons.arrow_drop_down,
                    color: Colors.white54,
                    size: widget.height > 30 ? 22 : 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

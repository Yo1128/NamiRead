import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the platform view mounted when a resize moves tools between sheet and side pane.
class ReaderPanes extends StatelessWidget {
  const ReaderPanes({
    super.key,
    required this.reader,
    required this.panel,
    required this.animation,
    required this.onClose,
    required this.paper,
    required this.ink,
  });

  final Widget Function(double width) reader;
  final Widget Function(double readingWidth, bool docked)? panel;
  final AnimationController animation;
  final VoidCallback onClose;
  final Color paper, ink;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final docked = bounds.maxWidth >= 900;
      final tools = panel;
      final modal = tools != null && !docked;
      final sideWidth = tools != null && docked
          ? (bounds.maxWidth * .29).clamp(312.0, 380.0).toDouble()
          : 0.0;
      final readingWidth = bounds.maxWidth - sideWidth;
      final progress = animation.drive(CurveTween(curve: Curves.easeOutCubic));
      // Reflow once per size change. Only the panel translates during its entrance.
      final body = Positioned.fill(
        right: sideWidth,
        child: ExcludeFocus(
          excluding: modal,
          child: ExcludeSemantics(
            excluding: modal,
            child: reader(readingWidth),
          ),
        ),
      );
      Widget panelFrame(Widget content) {
        if (docked) {
          return Container(
            width: sideWidth,
            height: bounds.maxHeight,
            decoration: BoxDecoration(
              color: paper,
              border: Border(
                left: BorderSide(color: ink.withValues(alpha: .14)),
              ),
            ),
            padding: const EdgeInsets.only(left: 1),
            child: content,
          );
        }
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 540,
            maxHeight: bounds.maxHeight * .88,
          ),
          child: BottomSheet(
            animationController: animation,
            backgroundColor: paper,
            clipBehavior: Clip.antiAlias,
            onClosing: onClose,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
            ),
            builder: (_) => content,
          ),
        );
      }

      return CallbackShortcuts(
        bindings: {
          if (tools != null)
            const SingleActivator(LogicalKeyboardKey.escape): onClose,
        },
        child: Stack(
          children: [
            body,
            if (modal)
              Positioned.fill(
                child: AnimatedModalBarrier(
                  color: ColorTween(
                    begin: Colors.transparent,
                    end: Colors.black54,
                  ).animate(progress),
                  dismissible: true,
                  onDismiss: onClose,
                  semanticsLabel: MaterialLocalizations.of(context)
                      .modalBarrierDismissLabel,
                ),
              ),
            if (tools != null)
              Positioned.fill(
                child: Align(
                  alignment: docked
                      ? Alignment.centerRight
                      : Alignment.bottomCenter,
                  child: SlideTransition(
                    position: Tween(
                      begin: docked ? const Offset(1, 0) : const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(progress),
                    child: FocusScope(
                      autofocus: true,
                      child: Semantics(
                        container: true,
                        scopesRoute: modal,
                        explicitChildNodes: true,
                        child: panelFrame(tools(readingWidth, docked)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

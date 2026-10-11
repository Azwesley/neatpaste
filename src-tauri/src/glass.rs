/// Keep desktop blur inside the same rounded shape as the web content. Tauri's
/// whole-window effect would also blur the six-point transparent outer margin.
pub fn update(window: &tauri::WebviewWindow, expanded: bool) {
    #[cfg(target_os = "macos")]
    {
        use objc2::MainThreadMarker;
        use objc2_app_kit::{
            NSAutoresizingMaskOptions, NSView, NSVisualEffectBlendingMode, NSVisualEffectMaterial,
            NSVisualEffectState, NSVisualEffectView, NSWindowOrderingMode,
        };
        use objc2_foundation::{NSPoint, NSRect, NSSize};

        let native_window = window.clone();
        if let Err(error) = window.run_on_main_thread(move || {
            let Some(main_thread) = MainThreadMarker::new() else {
                return;
            };
            let Ok(pointer) = native_window.ns_view() else {
                return;
            };
            // SAFETY: Tauri returns the window's live NSView. The cloned window
            // stays alive through this closure, which runs only on the main thread.
            let Some(content) = (unsafe { pointer.cast::<NSView>().as_ref() }) else {
                return;
            };
            let bounds = content.bounds();
            let frame = NSRect::new(
                NSPoint::new(bounds.origin.x + 6.0, bounds.origin.y + 6.0),
                NSSize::new(
                    (bounds.size.width - 12.0).max(0.0),
                    (bounds.size.height - 12.0).max(0.0),
                ),
            );
            let glass = content
                .subviews()
                .to_vec()
                .into_iter()
                .find_map(|view| view.downcast::<NSVisualEffectView>().ok())
                .unwrap_or_else(|| {
                    let view = NSVisualEffectView::initWithFrame(main_thread.alloc(), frame);
                    view.setMaterial(NSVisualEffectMaterial::Popover);
                    view.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
                    view.setState(NSVisualEffectState::Active);
                    view.setAutoresizingMask(
                        NSAutoresizingMaskOptions::ViewWidthSizable
                            | NSAutoresizingMaskOptions::ViewHeightSizable,
                    );
                    content.addSubview_positioned_relativeTo(
                        &view,
                        NSWindowOrderingMode::Below,
                        None,
                    );
                    view
                });
            glass.setFrame(frame);
            glass.setWantsLayer(true);
            if let Some(layer) = glass.layer() {
                layer.setCornerRadius(if expanded { 22.0 } else { 18.0 });
                layer.setMasksToBounds(true);
            }
        }) {
            // The transparent web surface remains usable if the effect cannot attach.
            eprintln!("Unable to update native glass: {error}");
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (window, expanded);
}

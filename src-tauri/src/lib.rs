mod basket;
mod glass;

use basket::SharedBasket;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, DragDropEvent, Emitter, Manager, WindowEvent,
};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

const SHORTCUT: &str = "CommandOrControl+Shift+Space";

#[derive(Clone, serde::Serialize)]
struct ShortcutStatus {
    available: bool,
    shortcut: &'static str,
    reason: Option<String>,
}

struct TrayStatus(AtomicBool);

#[tauri::command]
fn get_shortcut_status(status: tauri::State<'_, ShortcutStatus>) -> ShortcutStatus {
    status.inner().clone()
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn toggle_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false) {
            basket::save_position(app);
            let _ = window.hide();
        } else {
            show_main_window(app);
        }
    }
}

fn create_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "打开轻贴 · Open NeatPaste", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "退出 · Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &quit])?;
    #[cfg(target_os = "macos")]
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray.png"))?;
    #[cfg(not(target_os = "macos"))]
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))?;

    TrayIconBuilder::with_id("neatpaste-tray")
        .icon(icon)
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("轻贴 · NeatPaste")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_main_window(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main_window(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

pub fn run() {
    let app = tauri::Builder::default()
        // Keep this first: an additional process only raises the existing window.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            show_main_window(app);
        }))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _, event| {
                    if event.state == ShortcutState::Pressed {
                        toggle_main_window(app);
                    }
                })
                .build(),
        )
        .manage(TrayStatus(AtomicBool::new(false)))
        .manage(basket::new_state())
        .invoke_handler(tauri::generate_handler![
            get_shortcut_status,
            basket::get_basket,
            basket::choose_files,
            basket::remove_file,
            basket::clear_files,
            basket::set_expanded,
            basket::set_layout,
            basket::set_pinned,
            basket::park_island,
            basket::convert_files,
            basket::reveal_output,
            basket::hide_basket
        ])
        .setup(|app| {
            let shortcut_status = match app.global_shortcut().register(SHORTCUT) {
                Ok(()) => ShortcutStatus {
                    available: true,
                    shortcut: SHORTCUT,
                    reason: None,
                },
                Err(error) => ShortcutStatus {
                    available: false,
                    shortcut: SHORTCUT,
                    reason: Some(error.to_string()),
                },
            };
            app.manage(shortcut_status);

            match create_tray(app.handle()) {
                Ok(()) => app.state::<TrayStatus>().0.store(true, Ordering::Relaxed),
                // A missing system tray must never leave an invisible app running.
                Err(error) => eprintln!("System tray is unavailable: {error}"),
            }
            basket::initial_position(app.handle())?;
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                basket::save_position(window.app_handle());
                if window.state::<TrayStatus>().0.load(Ordering::Relaxed) && window.hide().is_ok() {
                    api.prevent_close();
                }
            }
            WindowEvent::DragDrop(DragDropEvent::Enter { .. }) => {
                let _ = window.emit("basket-drag", true);
            }
            WindowEvent::DragDrop(DragDropEvent::Leave) => {
                let _ = window.emit("basket-drag", false);
            }
            WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) => {
                let _ = window.emit("basket-drag", false);
                if let Err(error) = basket::add_paths(window.app_handle(), paths.clone()) {
                    let _ = window.emit("basket-error", error);
                }
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("Unable to start NeatPaste");

    app.run(|app, event| {
        if let tauri::RunEvent::ExitRequested { api, .. } = &event {
            basket::save_position(app);
            let state = app.state::<SharedBasket>();
            if basket::is_busy(&state) {
                if let Ok(mut basket) = state.lock() {
                    basket.quit_after_conversion = true;
                }
                api.prevent_exit();
                let _ = app.emit("basket-error", "正在完成转换，完成后会自动退出。");
            }
        }
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Reopen { .. } = event {
            show_main_window(app);
        }
    });
}

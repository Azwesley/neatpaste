use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    ffi::OsString,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize};

const MAX_FILES: usize = 10;
const COMPACT_SIZE: (f64, f64) = (208.0, 48.0);
const POSITION_PREFERENCE: &str = "island-position.json";
const IMAGE_FORMATS: &[&str] = &["png", "jpg", "heic", "tiff", "bmp", "gif", "pdf"];
const DOCUMENT_FORMATS: &[&str] = &["txt", "md", "pdf", "docx", "rtf", "html"];
const PDF_FORMATS: &[&str] = &["txt", "md", "docx", "rtf", "html", "png", "jpg"];
const DATA_FORMATS: &[&str] = &["csv", "tsv", "json"];
const VIDEO_FORMATS: &[&str] = &["gif"];
const OUTPUT_FORMATS: &[&str] = &[
    "png", "jpg", "heic", "tiff", "bmp", "gif", "pdf", "txt", "md", "docx", "rtf", "html", "csv",
    "tsv", "json",
];

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Layout {
    #[default]
    Empty,
    File,
    Batch,
    Animation,
    AnimationBatch,
    Settings,
}

impl Layout {
    fn for_file_count(count: usize) -> Self {
        match count {
            0 => Self::Empty,
            1 => Self::File,
            _ => Self::Batch,
        }
    }

    fn size(self) -> (f64, f64) {
        let height = match self {
            Self::Empty => 228.0,
            Self::File => 272.0,
            Self::Batch => 352.0,
            Self::Animation => 360.0,
            Self::AnimationBatch => 432.0,
            Self::Settings => 398.0,
        };
        (332.0, height)
    }

    fn for_items(items: &[Item]) -> Self {
        if items.iter().any(|item| is_animation(&item.entry.ext)) {
            if items.len() == 1 {
                Self::Animation
            } else {
                Self::AnimationBatch
            }
        } else {
            Self::for_file_count(items.len())
        }
    }
}

fn is_animation(ext: &str) -> bool {
    matches!(ext, "mov" | "mp4" | "livephoto")
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GifOptions {
    max_dimension: u16,
    fps: u8,
    #[serde(rename = "loop")]
    loop_forever: bool,
}

impl Default for GifOptions {
    fn default() -> Self {
        Self {
            max_dimension: 480,
            fps: 15,
            loop_forever: true,
        }
    }
}

impl GifOptions {
    fn validate(self) -> Result<Self, String> {
        if ![320, 480, 640].contains(&self.max_dimension) || ![10, 15, 20].contains(&self.fps) {
            return Err(
                "GIF 设置无效：尺寸请选择 320、480 或 640，帧率请选择 10、15 或 20。".into(),
            );
        }
        Ok(self)
    }
}

#[derive(Default)]
struct Placement {
    compact_anchor: Option<PhysicalPosition<i32>>,
    expanded_edge: Option<PhysicalPosition<i32>>,
}

impl Placement {
    fn anchor_for(
        &self,
        current_edge: PhysicalPosition<i32>,
        expanded: bool,
    ) -> PhysicalPosition<i32> {
        if expanded {
            if let (Some(anchor), Some(shown)) = (self.compact_anchor, self.expanded_edge) {
                // A clamped popover may have moved the visible icon. Only a subsequent
                // user drag changes the remembered compact position.
                return PhysicalPosition::new(
                    anchor.x + current_edge.x - shown.x,
                    anchor.y + current_edge.y - shown.y,
                );
            }
        }
        current_edge
    }
}

fn top_center(position: PhysicalPosition<i32>, size: PhysicalSize<u32>) -> PhysicalPosition<i32> {
    PhysicalPosition::new(position.x + size.width as i32 / 2, position.y)
}

fn default_anchor(
    area_position: PhysicalPosition<i32>,
    area_size: PhysicalSize<u32>,
    scale: f64,
) -> PhysicalPosition<i32> {
    PhysicalPosition::new(
        area_position.x + area_size.width as i32 / 2,
        area_position.y + (12.0 * scale).round() as i32,
    )
}

fn fit_window(
    anchor: PhysicalPosition<i32>,
    expanded: bool,
    layout: Layout,
    scale: f64,
    area_position: PhysicalPosition<i32>,
    area_size: PhysicalSize<u32>,
) -> (PhysicalPosition<i32>, PhysicalSize<u32>) {
    let (width, height) = if expanded {
        layout.size()
    } else {
        COMPACT_SIZE
    };
    let size = PhysicalSize::new(
        ((width * scale).round() as u32).min(area_size.width),
        ((height * scale).round() as u32).min(area_size.height),
    );
    let x = (anchor.x - size.width as i32 / 2).clamp(
        area_position.x,
        (area_position.x + area_size.width as i32 - size.width as i32).max(area_position.x),
    );
    let y = anchor.y.clamp(
        area_position.y,
        (area_position.y + area_size.height as i32 - size.height as i32).max(area_position.y),
    );
    (PhysicalPosition::new(x, y), size)
}

#[derive(Clone, Serialize)]
pub struct Entry {
    id: String,
    name: String,
    ext: String,
    size: u64,
    formats: Vec<String>,
    error: Option<String>,
}

#[derive(Clone)]
struct Item {
    entry: Entry,
    input: Option<PathBuf>,
    paired_photo: Option<PathBuf>,
    output: Option<PathBuf>,
}

pub struct Basket {
    items: Vec<Item>,
    expanded: bool,
    layout: Layout,
    content_layout: Layout,
    pinned: bool,
    busy: bool,
    completed: bool,
    next_id: u64,
    placement: Placement,
    pub quit_after_conversion: bool,
}

impl Basket {
    fn record_layout(&mut self, layout: Layout) {
        self.layout = layout;
        if layout != Layout::Settings {
            self.content_layout = layout;
        }
    }

    fn expansion_layout(&self, expanded: bool) -> Layout {
        if expanded && self.layout == Layout::Settings {
            Layout::Settings
        } else if self.completed {
            // Completion can show either a compact result or animation retry
            // controls. Preserve the frontend's last content layout across a
            // collapse or preferences visit, even when it needs no new render.
            self.content_layout
        } else {
            Layout::for_items(&self.items)
        }
    }
}

pub type SharedBasket = Arc<Mutex<Basket>>;

pub fn new_state() -> SharedBasket {
    Arc::new(Mutex::new(Basket {
        items: Vec::new(),
        expanded: false,
        layout: Layout::Empty,
        content_layout: Layout::Empty,
        pinned: true,
        busy: false,
        completed: false,
        next_id: 0,
        placement: Placement::default(),
        quit_after_conversion: false,
    }))
}

#[derive(Serialize)]
pub struct Snapshot {
    files: Vec<Entry>,
    expanded: bool,
    layout: Layout,
    pinned: bool,
    busy: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversionResult {
    id: String,
    name: String,
    ok: bool,
    output_name: Option<String>,
    error: Option<String>,
    warning: Option<String>,
}

#[derive(Deserialize)]
struct HelperResult {
    ok: bool,
    error: Option<String>,
    warning: Option<String>,
}

#[derive(Clone, Serialize)]
struct Progress {
    id: String,
    done: usize,
    total: usize,
}

fn lock(state: &SharedBasket) -> Result<std::sync::MutexGuard<'_, Basket>, String> {
    state
        .lock()
        .map_err(|_| "窗口状态异常，请重新打开轻贴。".into())
}

fn ensure_idle(basket: &Basket) -> Result<(), String> {
    if basket.busy {
        Err("正在转换，请完成后再调整文件。".into())
    } else {
        Ok(())
    }
}

pub fn is_busy(state: &SharedBasket) -> bool {
    state.lock().map(|b| b.busy).unwrap_or(false)
}

fn formats_for(ext: &str) -> (&'static [&'static str], u64) {
    match ext {
        "png" | "jpg" | "jpeg" | "webp" | "heic" | "heif" | "tiff" | "tif" | "bmp" | "gif" => {
            (IMAGE_FORMATS, 50 * 1024 * 1024)
        }
        "txt" | "md" | "docx" => (DOCUMENT_FORMATS, 20 * 1024 * 1024),
        "pdf" => (PDF_FORMATS, 20 * 1024 * 1024),
        "csv" | "tsv" | "json" => (DATA_FORMATS, 20 * 1024 * 1024),
        "mov" | "mp4" => (VIDEO_FORMATS, 100 * 1024 * 1024),
        _ => (&[], 0),
    }
}

fn inspect_file(path: &Path, id: String) -> Item {
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let ext = path
        .extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    let (formats, limit) = formats_for(&ext);
    let mut item = Item {
        entry: Entry {
            id,
            name,
            ext,
            size: 0,
            formats: formats.iter().map(|s| (*s).into()).collect(),
            error: None,
        },
        input: None,
        paired_photo: None,
        output: None,
    };
    let validation = (|| {
        let canonical = path.canonicalize().map_err(|_| "无法读取这个文件。")?;
        let meta = fs::metadata(&canonical).map_err(|_| "无法读取这个文件。")?;
        item.entry.size = meta.len();
        if !meta.is_file() {
            return Err("请放入文件，不支持文件夹。");
        }
        if formats.is_empty() {
            return Err("暂不支持这种文件格式。");
        }
        if meta.len() > limit {
            return Err("文件过大：视频最多 100 MB，图片最多 50 MB，文档最多 20 MB。");
        }
        if meta.len() == 0 {
            return Err("这个文件是空的。");
        }
        item.input = Some(canonical);
        Ok(())
    })();
    if let Err(error) = validation {
        item.entry.error = Some(error.into());
    }
    item
}

/// Only the explicitly supplied batch is considered. No sibling lookup or
/// cross-intake pairing can authorize an unselected photo or movie.
fn inspect_selection(paths: Vec<PathBuf>) -> Vec<Item> {
    let mut seen = HashSet::new();
    let mut selected = Vec::new();
    let mut groups: BTreeMap<(PathBuf, OsString), (Vec<usize>, Vec<usize>)> = BTreeMap::new();
    for path in paths {
        let canonical = path.canonicalize().ok();
        if !seen.insert(canonical.clone().unwrap_or_else(|| path.clone())) {
            continue;
        }
        let item = inspect_file(&path, String::new());
        if let Some(canonical) = canonical.as_ref() {
            if let (Some(parent), Some(stem)) = (canonical.parent(), canonical.file_stem()) {
                let group = groups
                    .entry((parent.to_path_buf(), stem.to_os_string()))
                    .or_default();
                match item.entry.ext.as_str() {
                    "heic" | "heif" | "jpg" | "jpeg" => group.0.push(selected.len()),
                    "mov" => group.1.push(selected.len()),
                    _ => {}
                }
            }
        }
        selected.push(item);
    }
    let mut partners = vec![None; selected.len()];
    for (photos, movies) in groups.values() {
        if let ([photo], [movie]) = (photos.as_slice(), movies.as_slice()) {
            if selected[*photo].entry.error.is_none() && selected[*movie].entry.error.is_none() {
                partners[*photo] = Some((*photo, *movie));
                partners[*movie] = Some((*photo, *movie));
            }
        }
    }
    let mut items = Vec::new();
    for (index, item) in selected.iter().enumerate() {
        if let Some((photo, movie)) = partners[index] {
            if index != photo.min(movie) {
                continue;
            }
            let mut paired = selected[movie].clone();
            let photo_path = selected[photo]
                .input
                .as_ref()
                .expect("validated selected photo");
            paired.entry.ext = "livephoto".into();
            paired.entry.name = format!(
                "{} · Live Photo",
                photo_path.file_stem().unwrap_or_default().to_string_lossy()
            );
            paired.paired_photo = Some(photo_path.clone());
            items.push(paired);
        } else {
            items.push(item.clone());
        }
    }
    items
}

fn emit_files(app: &AppHandle, state: &SharedBasket) {
    if let Ok(basket) = lock(state) {
        let _ = app.emit(
            "basket-files",
            basket
                .items
                .iter()
                .map(|i| i.entry.clone())
                .collect::<Vec<_>>(),
        );
    }
}

fn append_paths(basket: &mut Basket, paths: Vec<PathBuf>) -> Result<bool, String> {
    ensure_idle(basket)?;
    if paths.is_empty() {
        return Ok(false);
    }
    // Keep the finished results available until the next explicit intake. That
    // intake starts a new batch, so quick conversion cannot re-export old files.
    if basket.completed {
        basket.items.clear();
        basket.completed = false;
    }
    let paths = paths
        .into_iter()
        .filter(|path| {
            path.canonicalize().ok().is_none_or(|canonical| {
                !basket.items.iter().any(|item| {
                    item.input.as_ref() == Some(&canonical)
                        || item.paired_photo.as_ref() == Some(&canonical)
                })
            })
        })
        .collect();
    let mut overflow = false;
    for mut item in inspect_selection(paths) {
        if basket.items.iter().any(|existing| {
            item.input
                .iter()
                .chain(item.paired_photo.iter())
                .any(|path| {
                    existing.input.as_ref() == Some(path)
                        || existing.paired_photo.as_ref() == Some(path)
                })
        }) {
            continue;
        }
        if basket.items.len() >= MAX_FILES {
            overflow = true;
            break;
        }
        basket.next_id += 1;
        item.entry.id = format!("file-{}", basket.next_id);
        basket.items.push(item);
    }
    Ok(overflow)
}

pub fn add_paths(app: &AppHandle, paths: Vec<PathBuf>) -> Result<(), String> {
    let state = app.state::<SharedBasket>();
    let mut basket = lock(&state)?;
    let overflow = append_paths(&mut basket, paths)?;
    drop(basket);
    set_expanded_inner(app, true)?;
    emit_files(app, &state);
    if overflow {
        let _ = app.emit("basket-error", "一次最多放入 10 个文件，其余文件未加入。");
    }
    Ok(())
}

#[tauri::command]
pub fn get_basket(state: tauri::State<'_, SharedBasket>) -> Result<Snapshot, String> {
    let b = lock(&state)?;
    Ok(Snapshot {
        files: b.items.iter().map(|i| i.entry.clone()).collect(),
        expanded: b.expanded,
        layout: b.layout,
        pinned: b.pinned,
        busy: b.busy,
    })
}

#[tauri::command]
pub async fn choose_files(app: AppHandle) -> Result<(), String> {
    ensure_idle(&*lock(&app.state::<SharedBasket>())?)?;
    let files = rfd::AsyncFileDialog::new()
        .set_title("选择需要转换的文件")
        .add_filter(
            "图片、视频、文档和数据文件",
            &[
                "png", "jpg", "jpeg", "webp", "heic", "heif", "tiff", "tif", "bmp", "gif", "txt",
                "md", "docx", "pdf", "csv", "tsv", "json", "mov", "mp4",
            ],
        )
        .pick_files()
        .await;
    if let Some(files) = files {
        add_paths(&app, files.iter().map(|f| f.path().to_path_buf()).collect())?;
    }
    Ok(())
}

#[tauri::command]
pub fn remove_file(
    app: AppHandle,
    state: tauri::State<'_, SharedBasket>,
    id: String,
) -> Result<(), String> {
    let mut basket = lock(&state)?;
    ensure_idle(&basket)?;
    basket.items.retain(|item| item.entry.id != id);
    drop(basket);
    emit_files(&app, &state);
    Ok(())
}

#[tauri::command]
pub fn clear_files(app: AppHandle, state: tauri::State<'_, SharedBasket>) -> Result<(), String> {
    let mut basket = lock(&state)?;
    ensure_idle(&basket)?;
    basket.items.clear();
    basket.completed = false;
    drop(basket);
    emit_files(&app, &state);
    Ok(())
}

fn resize_window(app: &AppHandle, expanded: bool, layout: Layout) -> Result<(), String> {
    let window = app.get_webview_window("main").ok_or("窗口不可用。")?;
    let monitor = window
        .current_monitor()
        .map_err(|e| e.to_string())?
        .or(window.primary_monitor().map_err(|e| e.to_string())?)
        .ok_or("无法读取显示器位置。")?;
    let scale = monitor.scale_factor();
    let old_pos = window.outer_position().map_err(|e| e.to_string())?;
    let old_size = window.outer_size().map_err(|e| e.to_string())?;
    let state = app.state::<SharedBasket>();
    let anchor = {
        let basket = lock(&state)?;
        basket
            .placement
            .anchor_for(top_center(old_pos, old_size), basket.expanded)
    };
    let area = monitor.work_area();
    let (position, size) = fit_window(anchor, expanded, layout, scale, area.position, area.size);
    window.set_size(size).map_err(|e| e.to_string())?;
    window.set_position(position).map_err(|e| e.to_string())?;
    crate::glass::update(&window, expanded);
    {
        let mut basket = lock(&state)?;
        basket.expanded = expanded;
        basket.record_layout(layout);
        basket.placement.compact_anchor = Some(if expanded {
            anchor
        } else {
            top_center(position, size)
        });
        basket.placement.expanded_edge = expanded.then(|| top_center(position, size));
    }
    Ok(())
}

pub fn set_expanded_inner(app: &AppHandle, expanded: bool) -> Result<(), String> {
    let layout = {
        let state = app.state::<SharedBasket>();
        let basket = lock(&state)?;
        basket.expansion_layout(expanded)
    };
    resize_window(app, expanded, layout)?;
    let _ = app.emit("basket-expanded", expanded);
    Ok(())
}

#[tauri::command]
pub fn set_expanded(app: AppHandle, expanded: bool) -> Result<(), String> {
    set_expanded_inner(&app, expanded)
}

#[tauri::command]
pub fn set_layout(app: AppHandle, layout: Layout) -> Result<bool, String> {
    let expanded = {
        let state = app.state::<SharedBasket>();
        let mut basket = lock(&state)?;
        if basket.layout == layout {
            return Ok(basket.expanded);
        }
        if !basket.expanded {
            basket.record_layout(layout);
            return Ok(false);
        }
        basket.expanded
    };
    // Do not emit basket-expanded: layout changes originate from a rendered view
    // and must not start another expansion/render cycle.
    resize_window(&app, expanded, layout)?;
    Ok(expanded)
}

#[tauri::command]
pub fn set_pinned(
    app: AppHandle,
    state: tauri::State<'_, SharedBasket>,
    pinned: bool,
) -> Result<(), String> {
    app.get_webview_window("main")
        .ok_or("窗口不可用。")?
        .set_always_on_top(pinned)
        .map_err(|e| e.to_string())?;
    lock(&state)?.pinned = pinned;
    save_position(&app);
    Ok(())
}

#[derive(Serialize, Deserialize)]
struct PositionPreference {
    center: i32,
    top: i32,
    pinned: bool,
}

pub fn save_position(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let (Ok(pos), Ok(size), Ok(dir)) = (
        window.outer_position(),
        window.outer_size(),
        app.path().app_config_dir(),
    ) else {
        return;
    };
    let state = app.state::<SharedBasket>();
    let Ok(basket) = state.lock() else {
        return;
    };
    let anchor = basket
        .placement
        .anchor_for(top_center(pos, size), basket.expanded);
    let preference = PositionPreference {
        center: anchor.x,
        top: anchor.y,
        pinned: basket.pinned,
    };
    drop(basket);
    if let Ok(bytes) = serde_json::to_vec(&preference) {
        if fs::create_dir_all(&dir).is_ok() {
            let _ = fs::write(dir.join(POSITION_PREFERENCE), bytes);
        }
    }
}

pub fn initial_position(app: &AppHandle) -> tauri::Result<()> {
    let Some(window) = app.get_webview_window("main") else {
        return Ok(());
    };
    let saved = app
        .path()
        .app_config_dir()
        .ok()
        .and_then(|p| fs::read(p.join(POSITION_PREFERENCE)).ok())
        .and_then(|b| serde_json::from_slice::<PositionPreference>(&b).ok());
    let saved_monitor = saved.as_ref().and_then(|preference| {
        window
            .available_monitors()
            .ok()?
            .into_iter()
            .find(|monitor| {
                let area = monitor.work_area();
                preference.center > area.position.x
                    && preference.center <= area.position.x + area.size.width as i32
                    && preference.top > area.position.y
                    && preference.top <= area.position.y + area.size.height as i32
            })
    });
    if let Some(monitor) = saved_monitor.or(window.primary_monitor()?) {
        let area = monitor.work_area();
        let initial_anchor = default_anchor(area.position, area.size, monitor.scale_factor());
        let (center, top, pinned) = saved.map(|p| (p.center, p.top, p.pinned)).unwrap_or((
            initial_anchor.x,
            initial_anchor.y,
            true,
        ));
        let (position, size) = fit_window(
            PhysicalPosition::new(center, top),
            false,
            Layout::Empty,
            monitor.scale_factor(),
            area.position,
            area.size,
        );
        window.set_size(size)?;
        window.set_position(position)?;
        window.set_always_on_top(pinned)?;
        if let Ok(mut basket) = app.state::<SharedBasket>().lock() {
            basket.pinned = pinned;
            basket.placement.compact_anchor = Some(top_center(position, size));
        }
    }
    crate::glass::update(&window, false);
    window.show()?;
    Ok(())
}

#[tauri::command]
pub fn park_island(app: AppHandle) -> Result<(), String> {
    let window = app.get_webview_window("main").ok_or("窗口不可用。")?;
    let monitor = window
        .primary_monitor()
        .map_err(|e| e.to_string())?
        .ok_or("无法读取显示器位置。")?;
    let area = monitor.work_area();
    let anchor = default_anchor(area.position, area.size, monitor.scale_factor());
    let (expanded, layout) = {
        let state = app.state::<SharedBasket>();
        let basket = lock(&state)?;
        (basket.expanded, basket.layout)
    };
    let (position, size) = fit_window(
        anchor,
        expanded,
        layout,
        monitor.scale_factor(),
        area.position,
        area.size,
    );
    window.set_size(size).map_err(|e| e.to_string())?;
    window.set_position(position).map_err(|e| e.to_string())?;
    {
        let state = app.state::<SharedBasket>();
        let mut basket = lock(&state)?;
        basket.placement.compact_anchor = Some(anchor);
        basket.placement.expanded_edge = expanded.then(|| top_center(position, size));
    }
    save_position(&app);
    Ok(())
}

#[tauri::command]
pub fn hide_basket(app: AppHandle) -> Result<(), String> {
    save_position(&app);
    app.get_webview_window("main")
        .ok_or("窗口不可用。")?
        .hide()
        .map_err(|e| e.to_string())
}

fn output_directory(input: &Path) -> Result<PathBuf, String> {
    let directory = input
        .parent()
        .ok_or("找不到原文件所在文件夹。")?
        .join("轻贴导出");
    match fs::symlink_metadata(&directory) {
        Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
            return Err("导出位置不是普通文件夹，请检查「轻贴导出」。".into())
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir(&directory)
                .map_err(|_| "无法创建「轻贴导出」文件夹，请检查写入权限。")?;
        }
        Err(_) => return Err("无法访问导出文件夹。".into()),
    }
    Ok(directory)
}

#[cfg(target_os = "macos")]
fn atomic_move_exclusive(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let source = CString::new(source.as_os_str().as_bytes()).map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "Invalid source path")
    })?;
    let destination = CString::new(destination.as_os_str().as_bytes()).map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "Invalid destination path")
    })?;
    // RENAME_EXCL atomically moves the completed file only if the destination
    // does not exist. Avoid hard-link creation, which can stall on File Provider paths.
    // SAFETY: both paths are owned, NUL-terminated strings valid for this call.
    let result =
        unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "macos"))]
fn atomic_move_exclusive(_source: &Path, _destination: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "Native file conversion currently requires macOS",
    ))
}

fn commit_without_overwrite(
    temp: &Path,
    directory: &Path,
    stem: &str,
    format: &str,
) -> Result<PathBuf, String> {
    // Keep scratch and final paths on the same filesystem for atomic publication.
    let short_stem: String = stem.chars().take(60).collect();
    for n in 0..10_000 {
        let suffix = if n == 0 {
            String::new()
        } else {
            format!("-{n}")
        };
        let target = directory.join(format!("{short_stem}-轻贴{suffix}.{format}"));
        match atomic_move_exclusive(temp, &target) {
            Ok(()) => return Ok(target),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => {
                return Err("无法保存导出文件，请检查目标文件夹的写入权限和磁盘可用空间。".into())
            }
        }
    }
    Err("同名导出文件过多，请整理导出文件夹后重试。".into())
}

fn helper_path(app: &AppHandle) -> Result<PathBuf, String> {
    if let Ok(dir) = app.path().resource_dir() {
        let path = dir.join("neatpaste-convert");
        if path.is_file() {
            return Ok(path);
        }
    }
    #[cfg(debug_assertions)]
    {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../native/bin/neatpaste-convert");
        if path.is_file() {
            return Ok(path);
        }
    }
    Err("本地转换组件缺失，请重新安装轻贴。".into())
}

fn run_helper(
    helper: &Path,
    input: &Path,
    output: &Path,
    format: &str,
    gif_options: Option<GifOptions>,
) -> Result<Option<String>, String> {
    run_helper_with_timeout(
        helper,
        input,
        output,
        format,
        gif_options,
        Duration::from_secs(120),
    )
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HelperRequest<'a> {
    input: &'a Path,
    output: &'a Path,
    format: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    gif_options: Option<GifOptions>,
}

fn helper_request(
    input: &Path,
    output: &Path,
    format: &str,
    gif_options: Option<GifOptions>,
) -> Result<Vec<u8>, String> {
    let gif_options = gif_options.map(GifOptions::validate).transpose()?;
    serde_json::to_vec(&HelperRequest {
        input,
        output,
        format,
        gif_options,
    })
    .map_err(|e| e.to_string())
}

fn run_helper_with_timeout(
    helper: &Path,
    input: &Path,
    output: &Path,
    format: &str,
    gif_options: Option<GifOptions>,
    timeout: Duration,
) -> Result<Option<String>, String> {
    let request = helper_request(input, output, format, gif_options)?;
    let mut child = Command::new(helper)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "无法启动本地转换组件。")?;
    let write_result = child
        .stdin
        .take()
        .ok_or("转换组件未准备好。")
        .and_then(|mut stdin| stdin.write_all(&request).map_err(|_| "无法发送转换请求。"));
    if let Err(error) = write_result {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error.into());
    }
    // Only check the one active conversion process; idle baskets run no timer.
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("转换超时或组件异常，任务已停止，原文件已保留。".into());
            }
        }
    }
    let result = child.wait_with_output().map_err(|_| "转换组件意外退出。")?;
    let reply: HelperResult =
        serde_json::from_slice(&result.stdout).map_err(|_| "转换未完成，原文件已保留。")?;
    if !result.status.success() || !reply.ok {
        return Err(reply
            .error
            .unwrap_or_else(|| "转换失败，原文件已保留。".into()));
    }
    let size = fs::metadata(output)
        .map_err(|_| "转换组件未生成文件。")?
        .len();
    if size == 0 {
        return Err("转换结果为空，未保存文件。".into());
    }
    Ok(reply.warning)
}

fn convert_one(
    helper: &Path,
    item: &Item,
    format: &str,
    gif_options: Option<GifOptions>,
) -> Result<(PathBuf, Option<String>), String> {
    let gif_options = gif_options.map(GifOptions::validate).transpose()?;
    if let Some(error) = &item.entry.error {
        return Err(error.clone());
    }
    if !item.entry.formats.iter().any(|f| f == format) {
        return Err("这个文件不支持所选输出格式。".into());
    }
    let input = item.input.as_ref().ok_or("原文件不可用。")?;
    let current = inspect_file(input, item.entry.id.clone());
    if let Some(error) = current.entry.error {
        return Err(error);
    }
    let gif_options =
        (format == "gif" && is_animation(&item.entry.ext)).then(|| gif_options.unwrap_or_default());
    let dir = output_directory(input)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp_directory = dir.join(format!(".neatpaste-{}-{nonce}", std::process::id()));
    fs::create_dir(&temp_directory).map_err(|_| "导出文件夹不可写。")?;
    let temp = temp_directory.join(format!("converted.{format}"));
    let outcome = (|| {
        let warning = run_helper(helper, input, &temp, format, gif_options)?;
        let file = OpenOptions::new()
            .read(true)
            .open(&temp)
            .map_err(|_| "无法读取转换结果。")?;
        file.sync_all().map_err(|_| "无法完成文件写入。")?;
        let stem = input.file_stem().unwrap_or_default().to_string_lossy();
        let output = commit_without_overwrite(&temp, &dir, &stem, format)?;
        Ok((output, warning))
    })();
    if outcome.is_err() {
        let _ = fs::remove_file(&temp);
    }
    let _ = fs::remove_dir(&temp_directory);
    outcome
}

#[tauri::command]
pub async fn convert_files(
    app: AppHandle,
    state: tauri::State<'_, SharedBasket>,
    format: String,
    gif_options: Option<GifOptions>,
) -> Result<Vec<ConversionResult>, String> {
    if !OUTPUT_FORMATS.contains(&format.as_str()) {
        return Err("暂不支持这个输出格式。".into());
    }
    let gif_options = gif_options.map(GifOptions::validate).transpose()?;
    let helper = helper_path(&app)?;
    let state = state.inner().clone();
    let items = {
        let mut basket = lock(&state)?;
        ensure_idle(&basket)?;
        if basket.items.is_empty() {
            return Err("请先放入文件。".into());
        }
        basket.busy = true;
        basket.items.clone()
    };
    let worker_app = app.clone();
    let worker_state = state.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let total = items.len();
        let mut results = Vec::with_capacity(total);
        for (index, item) in items.iter().enumerate() {
            let _ = worker_app.emit(
                "basket-progress",
                Progress {
                    id: item.entry.id.clone(),
                    done: index,
                    total,
                },
            );
            let mut result = ConversionResult {
                id: item.entry.id.clone(),
                name: item.entry.name.clone(),
                ok: false,
                output_name: None,
                error: None,
                warning: None,
            };
            match convert_one(&helper, item, &format, gif_options) {
                Ok((output, warning)) => {
                    result.ok = true;
                    result.output_name =
                        output.file_name().map(|n| n.to_string_lossy().into_owned());
                    result.warning = warning;
                    if let Ok(mut basket) = lock(&worker_state) {
                        if let Some(stored) = basket
                            .items
                            .iter_mut()
                            .find(|i| i.entry.id == item.entry.id)
                        {
                            stored.output = Some(output);
                        }
                    }
                }
                Err(error) => result.error = Some(error),
            }
            results.push(result);
            let _ = worker_app.emit(
                "basket-progress",
                Progress {
                    id: item.entry.id.clone(),
                    done: index + 1,
                    total,
                },
            );
        }
        results
    })
    .await;
    let quit_after = {
        let mut basket = lock(&state)?;
        basket.busy = false;
        basket.completed = result.is_ok();
        basket.quit_after_conversion
    };
    if quit_after {
        app.exit(0);
    }
    result.map_err(|_| "转换任务中断，原文件已保留。".into())
}

#[tauri::command]
pub fn reveal_output(state: tauri::State<'_, SharedBasket>, id: String) -> Result<(), String> {
    let basket = lock(&state)?;
    let output = basket
        .items
        .iter()
        .find(|i| i.entry.id == id)
        .and_then(|i| i.output.as_ref())
        .ok_or("还没有可显示的导出文件。")?;
    if !output.is_file() {
        return Err("导出文件已移动或删除。".into());
    }
    #[cfg(target_os = "macos")]
    {
        Command::new("/usr/bin/open")
            .arg("-R")
            .arg(output)
            .spawn()
            .map_err(|_| "无法打开 Finder。")?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("当前版本仅支持 macOS。".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_protocol_accepts_only_fixed_presets() {
        for (name, layout, height) in [
            ("empty", Layout::Empty, 228.0),
            ("file", Layout::File, 272.0),
            ("batch", Layout::Batch, 352.0),
            ("animation", Layout::Animation, 360.0),
            ("animationbatch", Layout::AnimationBatch, 432.0),
            ("settings", Layout::Settings, 398.0),
        ] {
            assert_eq!(
                serde_json::from_value::<Layout>(serde_json::json!(name)).unwrap(),
                layout
            );
            assert_eq!(layout.size(), (332.0, height));
        }
        for invalid in [
            serde_json::json!("fullscreen"),
            serde_json::json!("Settings"),
            serde_json::json!({"width": 99999, "height": 99999}),
        ] {
            assert!(serde_json::from_value::<Layout>(invalid).is_err());
        }
        assert_eq!(Layout::for_file_count(0), Layout::Empty);
        assert_eq!(Layout::for_file_count(1), Layout::File);
        assert_eq!(Layout::for_file_count(MAX_FILES), Layout::Batch);
    }

    #[test]
    fn compact_anchor_survives_edge_clamped_expansion() {
        let anchor = PhysicalPosition::new(140, 800);
        let area = PhysicalPosition::new(0, 24);
        let bounds = PhysicalSize::new(1440, 876);
        let (expanded_position, expanded_size) =
            fit_window(anchor, true, Layout::Settings, 1.0, area, bounds);
        assert_eq!(expanded_position, PhysicalPosition::new(0, 502));
        assert_eq!(expanded_size, PhysicalSize::new(332, 398));
        let placement = Placement {
            compact_anchor: Some(anchor),
            expanded_edge: Some(top_center(expanded_position, expanded_size)),
        };
        let restored_anchor =
            placement.anchor_for(top_center(expanded_position, expanded_size), true);
        let (compact_position, compact_size) =
            fit_window(restored_anchor, false, Layout::Settings, 1.0, area, bounds);
        assert_eq!(top_center(compact_position, compact_size), anchor);
        // Repeated opening must not walk the compact object away from the edge.
        assert_eq!(
            placement.anchor_for(top_center(expanded_position, expanded_size), true),
            anchor
        );
    }

    #[test]
    fn changing_layout_at_display_edge_preserves_original_anchor() {
        let anchor = PhysicalPosition::new(140, 800);
        let area = PhysicalPosition::new(0, 24);
        let bounds = PhysicalSize::new(1440, 876);
        let mut placement = Placement {
            compact_anchor: Some(anchor),
            expanded_edge: None,
        };
        let mut current = anchor;
        for layout in [
            Layout::Settings,
            Layout::AnimationBatch,
            Layout::Animation,
            Layout::Empty,
            Layout::Batch,
            Layout::File,
        ] {
            let remembered = placement.anchor_for(current, true);
            assert_eq!(remembered, anchor);
            let (position, size) = fit_window(remembered, true, layout, 1.0, area, bounds);
            current = top_center(position, size);
            placement.expanded_edge = Some(current);
        }
        assert_eq!(placement.anchor_for(current, true), anchor);
    }

    #[test]
    fn expanded_drag_moves_remembered_compact_anchor_by_drag_delta() {
        let placement = Placement {
            compact_anchor: Some(PhysicalPosition::new(100, 120)),
            expanded_edge: Some(PhysicalPosition::new(336, 504)),
        };
        assert_eq!(
            placement.anchor_for(PhysicalPosition::new(376, 554), true),
            PhysicalPosition::new(140, 170)
        );
    }

    #[test]
    fn geometry_uses_display_scale_and_negative_monitor_coordinates() {
        let anchor = PhysicalPosition::new(-600, 72);
        let area = PhysicalPosition::new(-2880, 48);
        let bounds = PhysicalSize::new(2880, 1752);
        let (position, size) = fit_window(anchor, false, Layout::Settings, 2.0, area, bounds);
        assert_eq!(size, PhysicalSize::new(416, 96));
        assert_eq!(top_center(position, size), anchor);
        let (position, size) = fit_window(anchor, true, Layout::Settings, 2.0, area, bounds);
        assert_eq!(size, PhysicalSize::new(664, 796));
        assert_eq!(top_center(position, size), anchor);
    }

    #[test]
    fn oversized_popover_fits_small_work_area() {
        let area = PhysicalPosition::new(20, 30);
        let bounds = PhysicalSize::new(300, 300);
        let (position, size) = fit_window(
            PhysicalPosition::new(900, 800),
            true,
            Layout::Settings,
            1.0,
            area,
            bounds,
        );
        assert_eq!(position, area);
        assert_eq!(size, bounds);
    }

    #[test]
    fn island_defaults_below_menu_bar_and_expands_downward() {
        let area = PhysicalPosition::new(0, 48);
        let bounds = PhysicalSize::new(2880, 1752);
        let anchor = default_anchor(area, bounds, 2.0);
        assert_eq!(anchor, PhysicalPosition::new(1440, 72));
        let (compact_position, compact_size) =
            fit_window(anchor, false, Layout::Empty, 2.0, area, bounds);
        let (expanded_position, expanded_size) =
            fit_window(anchor, true, Layout::Empty, 2.0, area, bounds);
        assert_eq!(compact_position.y, expanded_position.y);
        assert_eq!(
            top_center(compact_position, compact_size),
            top_center(expanded_position, expanded_size)
        );
        assert_eq!(compact_position.x - expanded_position.x, 124);
    }

    #[test]
    fn supported_formats_stay_within_explicit_conversion_matrix() {
        assert_eq!(formats_for("gif"), (IMAGE_FORMATS, 50 * 1024 * 1024));
        assert_eq!(formats_for("heif"), (IMAGE_FORMATS, 50 * 1024 * 1024));
        assert_eq!(formats_for("docx").0, DOCUMENT_FORMATS);
        assert_eq!(formats_for("pdf").0, PDF_FORMATS);
        assert_eq!(formats_for("csv").0, DATA_FORMATS);
        assert_eq!(formats_for("tsv").0, DATA_FORMATS);
        assert_eq!(formats_for("json").0, DATA_FORMATS);
        assert_eq!(formats_for("mov"), (VIDEO_FORMATS, 100 * 1024 * 1024));
        assert_eq!(formats_for("mp4"), (VIDEO_FORMATS, 100 * 1024 * 1024));
        assert!(formats_for("rtf").0.is_empty());
        assert!(formats_for("html").0.is_empty());
        assert!(!IMAGE_FORMATS.contains(&"webp"));
        for input in [
            "png", "jpg", "webp", "heif", "gif", "txt", "md", "docx", "pdf", "csv", "tsv", "json",
            "mov", "mp4",
        ] {
            assert!(formats_for(input)
                .0
                .iter()
                .all(|format| OUTPUT_FORMATS.contains(format)));
        }
    }

    fn test_directory(label: &str) -> PathBuf {
        let base = std::env::var_os("NEATPASTE_TEST_DIRECTORY")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let p = base.join(format!(
            "neatpaste-{label}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&p).unwrap();
        p
    }

    fn selected_file(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, format!("original {name}")).unwrap();
        path
    }

    #[test]
    fn completed_animation_reopens_last_content_layout_after_settings_or_collapse() {
        let dir = test_directory("completed-layout");
        let state = new_state();
        let mut basket = lock(&state).unwrap();
        append_paths(&mut basket, vec![selected_file(&dir, "clip.mov")]).unwrap();
        assert_eq!(basket.expansion_layout(true), Layout::Animation);
        basket.completed = true;
        for layout in [
            Layout::File,
            Layout::Animation,
            Layout::Batch,
            Layout::AnimationBatch,
        ] {
            basket.record_layout(layout);
            assert_eq!(basket.expansion_layout(false), layout);
            assert_eq!(basket.expansion_layout(true), layout);
            basket.record_layout(Layout::Settings);
            assert_eq!(basket.expansion_layout(true), Layout::Settings);
            let collapsed_layout = basket.expansion_layout(false);
            assert_eq!(collapsed_layout, layout);
            basket.record_layout(collapsed_layout);
            assert_eq!(basket.expansion_layout(true), layout);
        }
        basket.record_layout(Layout::File);
        append_paths(&mut basket, vec![selected_file(&dir, "new-clip.mp4")]).unwrap();
        assert!(!basket.completed);
        assert_eq!(basket.expansion_layout(true), Layout::Animation);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn live_photo_pairs_only_unique_explicit_photo_and_mov_in_one_batch() {
        let dir = test_directory("live-pair");
        for extension in ["HEIC", "heif", "JPG", "jpeg"] {
            let photo = selected_file(&dir, &format!("capture.{extension}"));
            let movie = selected_file(&dir, "capture.MOV");
            for paths in [
                vec![photo.clone(), movie.clone()],
                vec![movie.clone(), photo.clone(), photo.clone()],
            ] {
                let items = inspect_selection(paths);
                assert_eq!(items.len(), 1);
                let item = &items[0];
                assert_eq!(item.entry.ext, "livephoto");
                assert_eq!(item.entry.name, "capture · Live Photo");
                assert_eq!(item.entry.formats, vec!["gif"]);
                assert_eq!(item.input, Some(movie.canonicalize().unwrap()));
                assert_eq!(item.paired_photo, Some(photo.canonicalize().unwrap()));
                assert_eq!(Layout::for_items(&items), Layout::Animation);
                assert_eq!(
                    fs::read_to_string(&photo).unwrap(),
                    format!("original capture.{extension}")
                );
                assert_eq!(fs::read_to_string(&movie).unwrap(), "original capture.MOV");
            }
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn live_photo_does_not_scan_or_pair_across_intakes_directories_or_ambiguity() {
        let dir = test_directory("live-no-pair");
        let other = test_directory("live-other");
        let photo = selected_file(&dir, "capture.heic");
        let alternate = selected_file(&dir, "capture.jpg");
        let movie = selected_file(&dir, "capture.mov");
        let foreign = selected_file(&other, "capture.mov");
        assert_eq!(inspect_selection(vec![photo.clone()])[0].entry.ext, "heic");
        assert_eq!(inspect_selection(vec![movie.clone()])[0].entry.ext, "mov");
        for paths in [
            vec![photo.clone(), foreign],
            vec![photo.clone(), alternate, movie.clone()],
        ] {
            let expected = paths.len();
            let items = inspect_selection(paths);
            assert_eq!(items.len(), expected);
            assert!(items.iter().all(|item| item.entry.ext != "livephoto"));
        }
        let mp4 = selected_file(&dir, "capture.mp4");
        assert_eq!(inspect_selection(vec![photo.clone(), mp4]).len(), 2);
        let state = new_state();
        let mut basket = lock(&state).unwrap();
        append_paths(&mut basket, vec![photo.clone()]).unwrap();
        append_paths(&mut basket, vec![photo, movie]).unwrap();
        assert_eq!(basket.items.len(), 2);
        assert_eq!(basket.items[0].entry.ext, "heic");
        assert_eq!(basket.items[1].entry.ext, "mov");
        assert_eq!(Layout::for_items(&basket.items), Layout::AnimationBatch);
        fs::remove_dir_all(dir).unwrap();
        fs::remove_dir_all(other).unwrap();
    }

    #[test]
    fn live_photo_pairing_precedes_item_limit_and_deduplicates_authorized_companions() {
        let dir = test_directory("live-limit");
        let mut paths = Vec::new();
        for index in 0..MAX_FILES {
            paths.push(selected_file(&dir, &format!("capture-{index}.heic")));
            paths.push(selected_file(&dir, &format!("capture-{index}.mov")));
        }
        let state = new_state();
        let mut basket = lock(&state).unwrap();
        assert!(!append_paths(&mut basket, paths.clone()).unwrap());
        assert_eq!(basket.items.len(), MAX_FILES);
        assert!(basket
            .items
            .iter()
            .all(|item| item.entry.ext == "livephoto"));
        assert!(!append_paths(&mut basket, paths).unwrap());
        assert!(append_paths(&mut basket, vec![selected_file(&dir, "extra.mp4")]).unwrap());
        assert_eq!(basket.items.len(), MAX_FILES);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn video_limit_is_one_hundred_mib_and_invalid_pairs_remain_visible() {
        let dir = test_directory("video-size");
        let movie = selected_file(&dir, "capture.mov");
        let file = OpenOptions::new().write(true).open(&movie).unwrap();
        file.set_len(100 * 1024 * 1024).unwrap();
        assert!(inspect_file(&movie, "1".into()).entry.error.is_none());
        file.set_len(100 * 1024 * 1024 + 1).unwrap();
        let photo = selected_file(&dir, "capture.heic");
        let items = inspect_selection(vec![photo, movie]);
        assert_eq!(items.len(), 2);
        assert!(items[1].entry.error.as_ref().unwrap().contains("100 MB"));
        assert_eq!(items[1].entry.formats, vec!["gif"]);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn gif_options_allow_only_bounded_presets_and_a_boolean_loop() {
        assert_eq!(
            serde_json::to_value(GifOptions::default()).unwrap(),
            serde_json::json!({"maxDimension":480,"fps":15,"loop":true})
        );
        for dimension in [320, 480, 640] {
            for fps in [10, 15, 20] {
                for repeat in [true, false] {
                    let options: GifOptions = serde_json::from_value(
                        serde_json::json!({"maxDimension":dimension,"fps":fps,"loop":repeat}),
                    )
                    .unwrap();
                    assert!(options.validate().is_ok());
                }
            }
        }
        for value in [
            serde_json::json!({"maxDimension":480,"fps":30,"loop":true}),
            serde_json::json!({"maxDimension":1920,"fps":15,"loop":true}),
            serde_json::json!({"maxDimension":480,"fps":15,"loop":1}),
            serde_json::json!({"maxDimension":480,"fps":15}),
            serde_json::json!({"maxDimension":480,"fps":15,"loop":true,"output":"elsewhere"}),
        ] {
            assert!(serde_json::from_value::<GifOptions>(value)
                .map_err(|e| e.to_string())
                .and_then(GifOptions::validate)
                .is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn helper_receives_gif_options_and_legacy_requests_omit_them() {
        use std::os::unix::fs::PermissionsExt;
        let dir = test_directory("gif-request");
        let helper = dir.join("helper");
        let output = dir.join("helper.output");
        fs::write(&helper, "#!/bin/sh\ncat > \"$0.request\"\nprintf GIF89a > \"$0.output\"\nprintf '%s' '{\"ok\":true}'\n").unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        for options in [
            None,
            Some(GifOptions::default()),
            Some(GifOptions {
                max_dimension: 320,
                fps: 10,
                loop_forever: false,
            }),
        ] {
            run_helper(
                &helper,
                &dir.join("explicit movie.mov"),
                &output,
                "gif",
                options,
            )
            .unwrap();
            let request: serde_json::Value =
                serde_json::from_slice(&fs::read(dir.join("helper.request")).unwrap()).unwrap();
            assert_eq!(
                request["input"],
                dir.join("explicit movie.mov").to_string_lossy().as_ref()
            );
            assert_eq!(request["output"], output.to_string_lossy().as_ref());
            assert_eq!(request["format"], "gif");
            if let Some(options) = options {
                assert_eq!(
                    request["gifOptions"],
                    serde_json::to_value(options).unwrap()
                );
            } else {
                assert!(request.get("gifOptions").is_none());
            }
            assert!(request.get("gif_options").is_none());
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn intake_after_finished_batch_replaces_old_queue_without_reusing_ids() {
        let dir = test_directory("next-batch");
        let original = dir.join("first.txt");
        let next = dir.join("second.txt");
        fs::write(&original, "first").unwrap();
        fs::write(&next, "second").unwrap();
        let state = new_state();
        let mut basket = lock(&state).unwrap();
        append_paths(&mut basket, vec![original.clone()]).unwrap();
        let first_id = basket.items[0].entry.id.clone();
        basket.completed = true;
        // A cancelled or empty picker must leave the finished results available.
        append_paths(&mut basket, Vec::new()).unwrap();
        assert_eq!(basket.items[0].entry.id, first_id);
        append_paths(&mut basket, vec![next.clone()]).unwrap();
        assert_eq!(basket.items.len(), 1);
        assert_eq!(basket.items[0].input, Some(next.canonicalize().unwrap()));
        assert_ne!(basket.items[0].entry.id, first_id);
        assert!(!basket.completed);
        assert_eq!(fs::read_to_string(original).unwrap(), "first");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn intake_before_conversion_appends_deduplicates_and_rejects_busy_changes() {
        let dir = test_directory("collect-batch");
        let first = dir.join("first.txt");
        let second = dir.join("second.txt");
        fs::write(&first, "first").unwrap();
        fs::write(&second, "second").unwrap();
        let state = new_state();
        let mut basket = lock(&state).unwrap();
        append_paths(&mut basket, vec![first.clone()]).unwrap();
        append_paths(&mut basket, vec![first.clone(), second.clone()]).unwrap();
        assert_eq!(basket.items.len(), 2);
        basket.completed = true;
        basket.busy = true;
        assert!(append_paths(&mut basket, vec![second]).is_err());
        assert_eq!(basket.items.len(), 2);
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn exclusive_rename_collision_preserves_both_files() {
        let dir = test_directory("exclusive-rename");
        let source = dir.join("scratch.pdf");
        let target = dir.join("already-there.pdf");
        fs::write(&source, "new data").unwrap();
        fs::write(&target, "existing data").unwrap();
        let error = atomic_move_exclusive(&source, &target).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read_to_string(&source).unwrap(), "new data");
        assert_eq!(fs::read_to_string(&target).unwrap(), "existing data");
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn exclusive_rename_rejects_destination_symlink() {
        let dir = test_directory("rename-symlink");
        let source = dir.join("scratch.pdf");
        let original = dir.join("original.pdf");
        let target = dir.join("link.pdf");
        fs::write(&source, "new data").unwrap();
        fs::write(&original, "original data").unwrap();
        std::os::unix::fs::symlink(&original, &target).unwrap();
        assert_eq!(
            atomic_move_exclusive(&source, &target).unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert_eq!(fs::read_to_string(original).unwrap(), "original data");
        assert!(source.is_file());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn save_never_overwrites_existing_file() {
        let dir = test_directory("save");
        let existing = dir.join("中文-轻贴.txt");
        fs::write(&existing, "original").unwrap();
        let temp = dir.join(".temp.txt");
        fs::write(&temp, "converted").unwrap();
        let saved = commit_without_overwrite(&temp, &dir, "中文", "txt").unwrap();
        assert_eq!(fs::read_to_string(existing).unwrap(), "original");
        assert_eq!(fs::read_to_string(&saved).unwrap(), "converted");
        assert!(saved.ends_with("中文-轻贴-1.txt"));
        assert!(!temp.exists());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rejects_directories_and_unsupported_inputs() {
        let dir = test_directory("inputs");
        assert!(inspect_file(&dir, "1".into()).entry.error.is_some());
        let file = dir.join("test.exe");
        fs::write(&file, "data").unwrap();
        assert!(inspect_file(&file, "2".into()).entry.error.is_some());
        fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn rejects_symlink_export_directory() {
        let dir = test_directory("symlink");
        let other = test_directory("elsewhere");
        let input = dir.join("a.txt");
        fs::write(&input, "data").unwrap();
        std::os::unix::fs::symlink(&other, dir.join("轻贴导出")).unwrap();
        assert!(output_directory(&input).is_err());
        fs::remove_dir_all(dir).unwrap();
        fs::remove_dir_all(other).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn helper_failure_is_not_reported_as_success() {
        use std::os::unix::fs::PermissionsExt;
        let dir = test_directory("helper");
        let helper = dir.join("helper");
        fs::write(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '%s' '{\"ok\":false,\"error\":\"invalid_input\"}'\n",
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            run_helper(
                &helper,
                &dir.join("input"),
                &dir.join("output"),
                "pdf",
                None
            )
            .unwrap_err(),
            "invalid_input"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn stalled_helper_is_stopped() {
        use std::os::unix::fs::PermissionsExt;
        let dir = test_directory("timeout");
        let helper = dir.join("helper");
        fs::write(&helper, "#!/bin/sh\ncat >/dev/null\nexec /bin/sleep 5\n").unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        let start = Instant::now();
        let result = run_helper_with_timeout(
            &helper,
            &dir.join("input"),
            &dir.join("output"),
            "txt",
            None,
            Duration::from_millis(30),
        );
        assert!(result.unwrap_err().contains("超时"));
        assert!(start.elapsed() < Duration::from_secs(2));
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn real_helper_exports_through_atomic_host_pipeline() {
        let helper = Path::new(env!("CARGO_MANIFEST_DIR")).join("../native/bin/neatpaste-convert");
        assert!(helper.is_file(), "Build the Swift helper before cargo test");
        let dir = test_directory("pipeline");
        let input = dir.join("中文样本.txt");
        let original = "轻贴保留原文件。\nNative helper integration.\n";
        fs::write(&input, original).unwrap();
        let item = inspect_file(&input, "file-test".into());
        let first = convert_one(&helper, &item, "txt", None).unwrap().0;
        let second = convert_one(&helper, &item, "txt", None).unwrap().0;
        assert_ne!(first, second);
        assert_eq!(fs::read_to_string(&input).unwrap(), original);
        assert_eq!(fs::read_to_string(&first).unwrap(), original);
        assert_eq!(fs::read_to_string(&second).unwrap(), original);
        assert_eq!(fs::read_dir(dir.join("轻贴导出")).unwrap().count(), 2);
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn real_helper_pdf_export_finishes_and_keeps_source() {
        let helper = Path::new(env!("CARGO_MANIFEST_DIR")).join("../native/bin/neatpaste-convert");
        let dir = test_directory("pdf-pipeline");
        let input = dir.join("原文.txt");
        let original = "这是一份转换后保留原文件的测试。\nPDF publication regression.\n";
        fs::write(&input, original).unwrap();
        let item = inspect_file(&input, "file-test".into());
        let first = convert_one(&helper, &item, "pdf", None).unwrap().0;
        let second = convert_one(&helper, &item, "pdf", None).unwrap().0;
        assert_ne!(first, second);
        assert!(fs::read(&first).unwrap().starts_with(b"%PDF-"));
        assert!(fs::read(&second).unwrap().starts_with(b"%PDF-"));
        assert_eq!(fs::read_to_string(input).unwrap(), original);
        assert_eq!(fs::read_dir(dir.join("轻贴导出")).unwrap().count(), 2);
        fs::remove_dir_all(dir).unwrap();
    }
}

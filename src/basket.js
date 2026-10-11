import './basket.css';
import { invoke, isTauri } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { availableFormats, selectFormat, summarizeResults, fileSize, conversionFamily, quickFormat, hasMotion, gifOptions } from './basket-model.js';

const native = isTauri();
const paths = {
  layers: '<rect x="4" y="3" width="11" height="14" rx="3"/><path d="M10 7h7a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3h-5a3 3 0 0 1-3-3V9"/>',
  pin: '<path d="m9 3 6 0-1 5 4 4v2H6v-2l4-4-1-5ZM12 14v7"/>',
  close: '<path d="m7 7 10 10M7 17 17 7"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  up: '<path d="m6 15 6-6 6 6M12 9v12M5 3h14"/>',
  down: '<path d="m6 9 6 6 6-6"/>',
  arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  file: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9l-6-6ZM14 3v6h6M8 13h8M8 17h5"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="9" cy="9" r="2"/><path d="m4 18 5-5 4 4 4-6 4 7"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  folder: '<path d="M3 7V5a2 2 0 0 1 2-2h5l3 3h6a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z"/><path d="M3 8h18"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  shield: '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Z"/><path d="m8 12 3 3 5-6"/>',
  refresh: '<path d="M20 7v5h-5M4 17v-5h5M5.6 7a7 7 0 0 1 12-2L20 8M4 16l2.4 3a7 7 0 0 0 12-2"/>',
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.file}</svg>`;
const copy = {
  zh: {
    name:'轻贴', subtitle:'文件换装，一拖就好', idleTitle:'拖进来，换个格式。', idleSub:'图片与文档 · 原文件好好留着', pick:'选择文件', preview:'查看示例', previewLabel:'界面预览', dropTitle:'放这里就好', dropSub:'松手，看看它能变成什么', ready:'准备换个格式', readySub:'给文件一个新的模样。', files:'个文件', output:'换成什么？', chooseHint:'只显示这组文件都支持的格式', keep:'原文件保留', destination:'另存到原文件旁的「轻贴导出」', destinationSub:'同名自动编号，不覆盖已有文件', convert:'开始转换', busy:'正在转换', doneTitle:'换好了，拿去用吧。', partialTitle:'有些文件需要再看一下', failedTitle:'这次没能完成转换', success:'份新文件已就绪', successOne:'转换成功', failed:'未完成', reveal:'在 Finder 中显示', again:'再转换一批', retry:'重试', add:'添加文件', remove:'移出队列', collapse:'收起投递篮', hide:'隐藏投递篮', settings:'偏好设置', pin:'保持置顶', unpin:'取消置顶', language:'语言', appearance:'外观', light:'浅色', dark:'深色', system:'跟随系统', done:'完成', desktopOnly:'请在 Mac 桌面版转换', noFormats:'这些文件没有共同的输出格式，请分批转换。', support:'图片：PNG / JPG / WebP / HEIC / TIFF / BMP\n文档：TXT / MD / DOCX / PDF\n最多 10 个文件；图片 50 MB，文档 20 MB。', supportTitle:'支持哪些文件？', privacy:'全部在本机完成，没有上传。关闭面板会收成小桌宠；完全退出请用菜单栏中的「退出」。', shortcutOkay:'⌘ ⇧ Space · 随时唤起', shortcutFailed:'快捷键不可用，请使用菜单栏图标', docsNote:'仅转换正文文字；页眉、脚注、图片和原版式不保留。Markdown 标记按原文保留。', pdfNote:'只提取 PDF 已有文字，扫描件暂不支持。', imageNote:'每张图片单独导出。JPG 的透明区域会填为白色。', imagePDFNote:'每张图片生成一份单页 PDF。', png:'PNG', pngSub:'保留透明背景', jpg:'JPG', jpgSub:'适合照片分享', pdf:'PDF', pdfSub:'方便阅读与发送', txt:'TXT', txtSub:'只留下文字', docx:'Word', docxSub:'文字重新排版', warning:'已完成，请留意', simpleReflow:'文档已按纯文字重新排版。', markdownLiteral:'Markdown 标记按原文保留。', alphaFlattened:'透明区域已填为白色。', firstImageOnly:'只转换第一帧图片。', noEmbeddedText:'没有可提取的文字，扫描 PDF 暂不支持。', inputTooLarge:'文件超过大小限制。', imageTooLarge:'图片超过 4000 万像素限制。', textTooLong:'文字超过 20 万字符限制。', tooManyPages:'文档超过 100 页限制。', invalidEncoding:'无法识别文字编码，请先另存为 UTF-8。', invalidInput:'文件内容无法读取或已损坏。', unsupportedConversion:'暂不支持这种转换。', outputExists:'输出文件已存在，请重试。', error:'操作未完成，请重试。', successReveal:'转换完成后可在 Finder 中查看',
  },
  en: {
    name:'NeatPaste', subtitle:'A new format. One small drop.', idleTitle:'Drop in. Change it up.', idleSub:'Images & documents. Originals stay.', pick:'Choose files', preview:'Try a sample', previewLabel:'Interface preview', dropTitle:'Right here is perfect.', dropSub:'Let go to see what it can become.', ready:'A little change of format.', readySub:'Same good file. A fresh new outfit.', files:'files', output:'Make it a…', chooseHint:'Formats available for every supported file', keep:'Originals stay', destination:'Saved beside each original, in “轻贴导出”', destinationSub:'Existing files are never overwritten', convert:'Convert files', busy:'Converting', doneTitle:'All dressed up. Ready to go.', partialTitle:'A few files need another look.', failedTitle:'These files couldn’t be converted.', success:'new files ready', successOne:'Converted', failed:'Not converted', reveal:'Show in Finder', again:'Start a new batch', retry:'Try again', add:'Add files', remove:'Remove file', collapse:'Collapse basket', hide:'Hide basket', settings:'Preferences', pin:'Keep on top', unpin:'Unpin window', language:'Language', appearance:'Appearance', light:'Light', dark:'Dark', system:'System', done:'Done', desktopOnly:'Convert in the Mac desktop app', noFormats:'These files have no shared output format. Convert them in separate batches.', support:'Images: PNG / JPG / WebP / HEIC / TIFF / BMP\nDocuments: TXT / MD / DOCX / PDF\nUp to 10 files. 50 MB per image, 20 MB per document.', supportTitle:'What can I drop?', privacy:'Everything happens on your Mac. Closing the panel leaves the little desktop companion. Use Quit in the menu bar to exit.', shortcutOkay:'⌘ ⇧ Space · show from anywhere', shortcutFailed:'Shortcut unavailable. Use the menu bar icon.', docsNote:'Only main-body text is converted; headers, notes, pictures and layout are not retained. Markdown markers stay literal.', pdfNote:'Extracts embedded PDF text. Scanned pages need OCR, which is not included.', imageNote:'Each image is exported separately. JPEG fills transparent areas with white.', imagePDFNote:'Each image becomes a separate one-page PDF.', png:'PNG', pngSub:'Keep transparency', jpg:'JPG', jpgSub:'Ready to share', pdf:'PDF', pdfSub:'Easy to read & send', txt:'TXT', txtSub:'Just the words', docx:'Word', docxSub:'Simple text layout', warning:'Converted, with a note', simpleReflow:'The document was rebuilt from plain text.', markdownLiteral:'Markdown markers were kept as written.', alphaFlattened:'Transparent areas were filled with white.', firstImageOnly:'Only the first image frame was converted.', noEmbeddedText:'No embedded text found. Scanned PDFs are not supported yet.', inputTooLarge:'This file exceeds the size limit.', imageTooLarge:'This image exceeds 40 megapixels.', textTooLong:'Text exceeds 200,000 characters.', tooManyPages:'Document exceeds 100 pages.', invalidEncoding:'Unknown text encoding. Save as UTF-8 first.', invalidInput:'The file could not be read or is damaged.', unsupportedConversion:'This conversion is not supported.', outputExists:'Output already exists. Please try again.', error:'Could not complete this action. Please try again.', successReveal:'Show the finished file in Finder',
  },
};
Object.assign(copy.zh, {
  petHint:'轻贴 · 单击打开，拖动换位置，右键设置',
  conversionFailed:'未能生成有效文件，请检查原文件后重试。',
  expandedDocumentTooLarge:'Word 文件解压后过大，超过 40 MB 限制。',
  invalidPath:'文件位置不可用，请重新选择文件。',
  passwordProtected:'这个 PDF 有密码保护，请先解锁文件。',
  unsupportedInput:'暂不支持这种文件类型。',
  somePagesWithoutText:'部分页面没有可提取文字，结果仅包含可读取的页面。',
});
Object.assign(copy.en, {
  petHint:'NeatPaste · Click to open, drag to move, right-click for settings',
  conversionFailed:'Could not create a valid output. Check the original and try again.',
  expandedDocumentTooLarge:'The expanded Word document exceeds 40 MB.',
  invalidPath:'This file location is unavailable. Please choose the file again.',
  passwordProtected:'This PDF is password-protected. Unlock it first.',
  unsupportedInput:'This file type is not supported yet.',
  somePagesWithoutText:'Some pages contain no extractable text. Only readable pages were included.',
});

Object.assign(copy.zh, {
  csv:'CSV',csvSub:'逗号分隔表格',tsv:'TSV',tsvSub:'制表符分隔表格',json:'JSON',jsonSub:'二维文字数组',dataNote:'保留行列与首行。JSON 使用二维字符串数组；不会推断数字或表头。',
  gifPaletteLimited:'GIF 只保留静态画面，颜色减少至 256 色。',pdfTextReflow:'PDF 按提取文字重排，不保留原版式。',
  invalidTable:'无法读取表格结构，请检查分隔符和引号。',unsupportedJSONShape:'JSON 需为行列整齐的二维字符串数组，不支持对象或数值单元格。',tooManyCells:'表格超过 50,000 个单元格限制。',spreadsheetFormulaLike:'保留了以公式符号开头的文字；表格软件可能将它们作为公式处理。',
  dropHere:'拖入文件，换个格式', open:'打开轻贴转换岛', collapse:'收起转换岛', local:'本地转换', move:'拖动此图标移动转换岛', dropAnywhere:'把文件拖到这里', emptyTitle:'文件放进来，格式交给我', release:'松手，开始换装', needsAttention:'有文件需要检查', readyDone:'转换完成，点击取走',
  quick:'拖入即转换',quickHint:'使用该类文件上次转换的格式；首次仍需选择。', park:'回到屏幕顶部', privacy:'所有转换都在本机完成。按 Esc 收起胶囊，从菜单栏退出应用。',
  support:'图片输入：PNG / JPG / WebP / HEIC / HEIF / TIFF / BMP / GIF\n文档输入：TXT / MD / DOCX / PDF\n图片输出：PNG / JPG / HEIC / TIFF / BMP / GIF / PDF\n文字输出：TXT / MD / PDF / DOCX / RTF / HTML\n数据表格：CSV / TSV / JSON 互转。\nPDF 可转图片（仅首页）或提取文字。最多 10 个文件。',
  imageNote:'每张图片独立转换，动图和多帧图片只取第一帧。', opaqueNote:'透明区域填为白色；动图和多帧图片只取第一帧。', pdfImageNote:'仅导出 PDF 首页，144 dpi；不包含后续页面。', pdfNote:'提取已有正文文字并重排，不保留原版式；扫描件不做文字识别。',
  heic:'HEIC',heicSub:'节省图片空间',tiff:'TIFF',tiffSub:'无损图像',bmp:'BMP',bmpSub:'位图',gif:'GIF',gifSub:'静态图片',md:'MD',mdSub:'纯文字 Markdown',rtf:'RTF',rtfSub:'可编辑文字',html:'HTML',htmlSub:'离线文字网页',
  firstPageOnly:'只导出了 PDF 的第一页。',staticGIF:'导出为静态 GIF，不保留动画。',encoderUnavailable:'这台 Mac 暂不支持此格式编码。',
});
Object.assign(copy.en, {
  csv:'CSV',csvSub:'Comma-separated table',tsv:'TSV',tsvSub:'Tab-separated table',json:'JSON',jsonSub:'Rows of text cells',dataNote:'Preserves rows, columns and row 1. JSON uses arrays of text rows; no inferred types or headers.',
  gifPaletteLimited:'A still GIF with at most 256 colors was exported.',pdfTextReflow:'PDF text was reflowed without its original layout.',
  invalidTable:'Unable to read this table. Check its delimiters and quotes.',unsupportedJSONShape:'JSON must be a rectangular array of string rows, without objects or numeric cells.',tooManyCells:'The table exceeds 50,000 cells.',spreadsheetFormulaLike:'Formula-like text was preserved; spreadsheet software may interpret it as formulas.',
  dropHere:'Drop a file. Change it up.',open:'Open NeatPaste island',collapse:'Collapse island',local:'On your Mac',move:'Drag this icon to move the island',dropAnywhere:'Drop files here',emptyTitle:'Your files. A fresh format.',release:'Let go to change it up',needsAttention:'Some files need attention',readyDone:'Ready. Click to pick up.',
  quick:'Convert on drop',quickHint:'Use the last format for this file type. Choose once first.',park:'Return to the top',privacy:'Everything stays on your Mac. Escape folds the island away. Quit from the menu bar.',
  support:'Image input: PNG / JPG / WebP / HEIC / HEIF / TIFF / BMP / GIF\nDocument input: TXT / MD / DOCX / PDF\nImage output: PNG / JPG / HEIC / TIFF / BMP / GIF / PDF\nText output: TXT / MD / PDF / DOCX / RTF / HTML\nTables: CSV / TSV / JSON.\nPDF images export page 1 only. Up to 10 files.',
  imageNote:'Each image is separate. Animation and multi-image files export frame 1 only.',opaqueNote:'Transparency is filled white. Only the first image frame is exported.',pdfImageNote:'Exports PDF page 1 only at 144 dpi. Later pages are not included.',pdfNote:'Reflows existing body text without the original layout. No OCR for scanned pages.',
  heic:'HEIC',heicSub:'Efficient images',tiff:'TIFF',tiffSub:'Lossless image',bmp:'BMP',bmpSub:'Bitmap',gif:'GIF',gifSub:'Still image',md:'MD',mdSub:'Plain text Markdown',rtf:'RTF',rtfSub:'Editable text',html:'HTML',htmlSub:'Offline text page',
  firstPageOnly:'Only the first PDF page was exported.',staticGIF:'A still GIF was exported. Animation is not retained.',encoderUnavailable:'This Mac cannot encode this format.',
});

Object.assign(copy.zh, {
  subtitle:'本地文件转换', dropHere:'拖入转换', emptyTitle:'拖入文件', idleSub:'图片、文档或表格',
  pick:'选择文件…', preview:'查看示例', previewLabel:'界面预览 · 转换请打开 Mac 版',
  pdfWordNote:'文字可编辑、图片内嵌；复杂页保留为图片。', pdfImagesReflow:'图片已内嵌，图文重新排版。', pdfVisualFallback:'复杂页面已作为整页图片保留，其中的文字无法直接编辑。', pdfTextInImages:'图片上重叠的文字已保留在图片中，无法单独编辑。', pdfImageLimit:'PDF 图片内容超过处理限制，请拆分文件后再试。', pdfUnsupportedAnnotation:'此 PDF 含暂不支持的可见批注。请先将批注合并到 PDF 页面后再试。',
  selection:'不可用', output:'格式', convert:'转换', keep:'保留原件', readyDone:'转换完成', release:'松开以添加文件',
  panelTitle:'文件转换', doneTitle:'转换完成', partialTitle:'部分完成', failedTitle:'转换未完成',
  success:'个已完成', queue:'文件', clear:'清空', done:'完成', settings:'设置',
  localFoot:'仅在本机处理', destination:'原文件旁的「轻贴导出」', destinationLabel:'存储位置',
  imageNote:'动图与多帧图片只导出第一帧。', opaqueNote:'透明区域填为白色；只导出第一帧。',
  docsNote:'仅保留正文文字，不保留图片和原版式。', pdfNote:'提取已有文字并重排；扫描件不支持。',
  dataNote:'保留行列。JSON 使用二维字符串数组。',
  collapse:'收起', open:'打开文件转换', move:'拖动图标移动窗口',
});
Object.assign(copy.en, {
  subtitle:'Local file conversion', dropHere:'Drop to convert', emptyTitle:'Drop files here', idleSub:'Images, documents or tables',
  pick:'Choose Files…', preview:'Try a sample', previewLabel:'Preview · Convert in the Mac app',
  pdfWordNote:'Text + images; complex pages stay images.', pdfImagesReflow:'Embedded images; text reflowed.', pdfVisualFallback:'Complex pages were kept as full-page images; their text is not editable.', pdfTextInImages:'Text overlapping images stays inside those images and is not separately editable.', pdfImageLimit:'PDF image content exceeds processing limits. Split the file and try again.', pdfUnsupportedAnnotation:'This PDF has unsupported visible annotations. Flatten them into the PDF pages first.',
  selection:'Unavailable', output:'Format', convert:'Convert', keep:'Keep originals', readyDone:'Converted', release:'Release to add files',
  panelTitle:'Convert Files', doneTitle:'Conversion complete', partialTitle:'Partially complete', failedTitle:'Conversion incomplete',
  success:'converted', queue:'Files', clear:'Clear', done:'Done', settings:'Settings',
  localFoot:'Processed on your Mac', destination:'“轻贴导出”, beside the original', destinationLabel:'Save to',
  imageNote:'Animation and multi-image files export frame 1.', opaqueNote:'Transparency becomes white. Frame 1 only.',
  docsNote:'Body text only. Images and layout are not retained.', pdfNote:'Reflows embedded text. No OCR for scans.',
  dataNote:'Keeps rows and columns. JSON uses string rows.',
  collapse:'Collapse', open:'Open file converter', move:'Drag this icon to move the window',
});
Object.assign(copy.zh, {
  gifSettings:'动态 GIF 设置', gifSize:'最长边', gifFPS:'帧率', gifLoop:'循环播放',
  motionNote:'动态 GIF，无声音。最长 15 秒，100 MB。', mixedMotionNote:'视频转动图，照片转静态 GIF。无声音。',
  liveStillNote:'静态 GIF；实况动图请同时添加配套 MOV。',
  invalidGifOptions:'GIF 参数无效，请重新选择尺寸和帧率。', invalidVideo:'视频内容无法读取或已损坏。', videoProtected:'视频有播放保护，无法转换。', videoNoTrack:'文件中没有可读取的视频画面。', videoTooLong:'视频超过 15 秒，请先裁剪后再试。', videoTooShort:'视频太短，无法生成动态 GIF。', videoDecodeFailed:'无法解码视频画面，请尝试导出为 MOV 或 MP4。', gifResourceLimit:'GIF 超过处理或体积限制，请降低尺寸或帧率。', videoMetadataTimeout:'读取视频超时，请重新导出文件后再试。',
  animatedGifLossy:'动态 GIF，最多 256 色。', videoAudioRemoved:'声音已去除。',
});
Object.assign(copy.en, {
  gifSettings:'Animated GIF settings', gifSize:'Max edge', gifFPS:'Frame rate', gifLoop:'Loop playback',
  motionNote:'Animated, silent GIF. Up to 15 s and 100 MB.', mixedMotionNote:'Videos animate; photos stay still. No audio.',
  liveStillNote:'Still GIF. Add the matching MOV for motion.',
  invalidGifOptions:'Invalid GIF settings. Choose a size and frame rate again.', invalidVideo:'The video is damaged or could not be read.', videoProtected:'Protected videos cannot be converted.', videoNoTrack:'No readable video track was found.', videoTooLong:'Video exceeds 15 seconds. Trim it first.', videoTooShort:'Video is too short to create an animated GIF.', videoDecodeFailed:'Could not decode this video. Try exporting it as MOV or MP4.', gifResourceLimit:'GIF exceeds processing or size limits. Lower the size or frame rate.', videoMetadataTimeout:'Video metadata timed out. Export the video again.',
  animatedGifLossy:'Animated GIF, up to 256 colors.', videoAudioRemoved:'Audio removed.',
});
copy.zh.support+='\n动态 GIF：MOV / MP4，最长 15 秒、100 MB。\n实况照片：在「照片」导出未修改的原片，将同目录同名的照片与 MOV 同时拖入。仅有 HEIC/JPG 时为静态图。';
copy.en.support+='\nAnimated GIF: MOV / MP4, up to 15 seconds and 100 MB.\nLive Photo: export unmodified originals from Photos, then add the matching photo and MOV from the same folder together. A lone HEIC/JPG is still.';
paths.tray = '<path d="M12 3v10m-4-4 4 4 4-4M5 12l-2 5v3a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1v-3l-2-5M3 17h5l2 2h4l2-2h5"/>';
paths.minus = '<path d="M6 12h12"/>';
paths.lock = '<rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v3"/>';
paths.sliders = '<path d="M4 7h7m4 0h5M4 17h3m4 0h9"/><circle cx="13" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>';

let prefs = {};
try { prefs = JSON.parse(localStorage.getItem('neatpaste.basket.preferences') || '{}') || {}; } catch { /* Use defaults. */ }
const state = {
  lang:['zh','en'].includes(prefs.lang) ? prefs.lang : navigator.language.startsWith('zh') ? 'zh':'en',
  theme:['light','dark','system'].includes(prefs.theme) ? prefs.theme : 'system',
  quick: prefs.quick === true, remembered: prefs.remembered && typeof prefs.remembered==='object' ? prefs.remembered : {},
  gifOptions:gifOptions(prefs.gifOptions),
  files:[], results:[], expanded:false, pinned:true, busy:false, format:null, drag:false, settings:false, progress:0, total:0, error:'', shortcut:null, picking:false,
};
let autoBatch='';
const family = (files=state.files)=>conversionFamily(files);
const $ = selector => document.querySelector(selector);
const t = key => copy[state.lang][key] || key;
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const images = new Set(['png','jpg','jpeg','webp','heic','heif','tif','tiff','bmp','gif']);
const message = value => value ? value.split(/[;,]/).map(part => t(part.trim())).join(' ') : '';

function savePrefs() {
  try { localStorage.setItem('neatpaste.basket.preferences',JSON.stringify({lang:state.lang,theme:state.theme,quick:state.quick,remembered:state.remembered,gifOptions:state.gifOptions})); } catch { /* Content never depends on storage. */ }
}
function ingest(files) {
  const changed = JSON.stringify(files.map(file=>file.id)) !== JSON.stringify(state.files.map(file=>file.id));
  if(files.some(file=>!state.files.some(current=>current.id===file.id)))document.querySelector('.file-list')?.scrollTo(0,0);
  state.files = files;
  if (changed) { state.results = []; state.error = ''; }
  state.format = selectFormat(files,state.remembered[family(files)] || state.format);
}
async function refresh() {
  if (!native) return;
  const current = await invoke('get_basket');
  ingest(current.files);
  state.expanded=current.expanded; state.pinned=current.pinned; state.busy=current.busy;
  render();
}
const layouts = { empty:228, file:272, batch:352, animation:360, animationbatch:432, settings:398 };
let desiredLayout = 'empty';
let syncedLayout = '';
let syncingLayout = false;
function syncLayout() {
  if (!native || syncingLayout || desiredLayout === syncedLayout) return;
  syncingLayout = true;
  (async () => {
    try {
      while (desiredLayout !== syncedLayout) {
        const next = desiredLayout;
        await invoke('set_layout', {layout:next});
        syncedLayout = next;
      }
    } catch (error) { console.error('Unable to resize panel', error); }
    finally { syncingLayout = false; }
  })();
}
function fileRow(file) {
  const result = state.results.find(result => result.id === file.id);
  const error = file.error || (result && !result.ok ? result.error : null);
  const name = result?.ok ? result.outputName : file.name;
  const ext = result?.ok ? name.split('.').at(-1) : file.ext;
  return `<article class="file-row ${error?'file-error':''}">
    <span class="document-icon ${images.has(file.ext.toLowerCase())?'photo':''}" aria-hidden="true">${icon(images.has(file.ext.toLowerCase())?'image':'file')}<b>${escape(ext==='livephoto'?'LIVE':ext.toUpperCase())}</b></span>
    <div class="file-info"><strong title="${escape(name)}">${escape(name)}</strong>
      <span>${error?escape(message(error)):result?.ok?`<span class="success-text">${icon('check')}${t('successOne')}</span>`:`${escape(file.ext==='livephoto'?'Live Photo':file.ext.toUpperCase()||'FILE')} · ${fileSize(file.size)}`}</span>
      ${result?.warning?`<small class="file-warning">${escape(message(result.warning))}</small>`:''}
    </div>
    ${result?.ok?`<button class="icon-button" data-reveal="${escape(file.id)}" aria-label="${t('reveal')}: ${escape(name)}" title="${t('reveal')}">${icon('folder')}</button>`:`<button class="icon-button remove" data-remove="${escape(file.id)}" aria-label="${t('remove')}: ${escape(name)}" ${state.busy?'disabled':''}>${icon('close')}</button>`}
  </article>`;
}
function motionControls() {
  return `<div class="motion-options" role="group" aria-label="${t('gifSettings')}">
    <div class="motion-selects">
      <label for="gif-size">${t('gifSize')}<select id="gif-size" ${state.busy?'disabled':''}>${[320,480,640].map(size=>`<option value="${size}" ${state.gifOptions.maxDimension===size?'selected':''}>${size} px</option>`).join('')}</select></label>
      <label for="gif-fps">${t('gifFPS')}<select id="gif-fps" ${state.busy?'disabled':''}>${[10,15,20].map(fps=>`<option value="${fps}" ${state.gifOptions.fps===fps?'selected':''}>${fps} fps</option>`).join('')}</select></label>
    </div>
    <label class="motion-loop">${t('gifLoop')}<input type="checkbox" role="switch" id="gif-loop" ${state.gifOptions.loop?'checked':''} ${state.busy?'disabled':''}></label>
  </div>`;
}
function settingsContent() {
  return `<dialog id="preferences-dialog" class="settings-layer" aria-label="${t('settings')}">
    <header class="settings-header"><h2>${t('settings')}</h2><button id="close-settings" class="text-button">${t('done')}</button></header>
    <div class="settings-content">
      <div class="settings-group">
        <label>${t('language')}<select id="lang"><option value="zh" ${state.lang==='zh'?'selected':''}>简体中文</option><option value="en" ${state.lang==='en'?'selected':''}>English</option></select></label>
        <label>${t('appearance')}<select id="theme">${['system','light','dark'].map(theme=>`<option value="${theme}" ${state.theme===theme?'selected':''}>${t(theme)}</option>`).join('')}</select></label>
      </div>
      <div class="settings-group">
        <label><span>${t('quick')}<small>${t('quickHint')}</small></span><input type="checkbox" role="switch" id="quick" ${state.quick?'checked':''}></label>
        <label>${t('pin')}<input type="checkbox" role="switch" id="pin" ${state.pinned?'checked':''} ${!native?'disabled':''}></label>
      </div>
      <button class="park-button" id="park" ${!native?'disabled':''}>${t('park')}${icon('up')}</button>
      <p class="shortcut-status">${t(state.shortcut?.available?'shortcutOkay':native?'shortcutFailed':'previewLabel')}</p>
      <details><summary>${t('supportTitle')}</summary><p>${t('support')}</p><p>${t('privacy')}</p></details>
      <footer><span>NeatPaste</span><span>0.6.0</span></footer>
    </div>
  </dialog>`;
}
function render() {
  const focusedId = document.activeElement?.id;
  const scrollers = ['.expanded-content','.file-list','.settings-content'].map(selector => [selector, document.querySelector(selector)?.scrollTop || 0]);
  const supportOpen = document.querySelector('.settings-content details')?.open;
  const usable = state.files.filter(file=>!file.error && file.formats.length);
  const formats = availableFormats(state.files);
  const summary = summarizeResults(state.files,state.results);
  const finished = state.results.length > 0;
  const empty = !state.files.length;
  const allImages = usable.length > 0 && usable.every(file=>images.has(file.ext.toLowerCase()));
  const firstOutput = state.results.find(result=>result.ok);
  const motion = hasMotion(usable) && state.format==='gif';
  const showMotionOptions = motion && (!finished || summary.success===0);
  desiredLayout = state.settings ? 'settings' : empty ? 'empty' : showMotionOptions ? state.files.length===1?'animation':'animationbatch' : state.files.length===1 ? 'file' : 'batch';
  document.documentElement.lang=state.lang==='zh'?'zh-CN':'en';
  document.documentElement.dataset.theme=state.theme;
  document.body.classList.toggle('browser',!native);
  document.title=`${t('name')} · ${t('subtitle')}`;
  $('#app').style.setProperty('--expanded-height',`${layouts[desiredLayout]}px`);
  const status = state.drag?t('release'):state.busy?`${t('busy')} ${state.progress}/${state.total}`:finished?(summary.failed?t('needsAttention'):t('readyDone')):state.files.length?`${state.files.length} ${t('files')}`:t('dropHere');
  const note = motion ? (usable.every(f=>['mov','mp4','livephoto'].includes(f.ext.toLowerCase()))?'motionNote':'mixedMotionNote') : family()==='data' ? 'dataNote' : allImages ? state.format==='pdf'?'imagePDFNote':state.format==='gif'&&usable.some(f=>['heic','heif','jpg','jpeg'].includes(f.ext.toLowerCase()))?'liveStillNote':['jpg','heic','bmp','gif'].includes(state.format)?'opaqueNote':'imageNote' : usable.some(f=>f.ext==='pdf') ? ['png','jpg'].includes(state.format)?'pdfImageNote':state.format==='docx'?'pdfWordNote':'pdfNote' : 'docsNote';
  $('#app').innerHTML=`<section class="island ${state.expanded?'expanded':'compact'} ${empty?'is-empty':''} ${finished?'is-finished':''} ${state.drag?'drag-over':''} ${state.busy?'working':''}" data-layout="${desiredLayout}" aria-label="${t('name')}">
    <header class="island-header">
      <span class="signal ${finished?(summary.failed?'warning':'success'):''}" id="drag-handle" title="${t('move')}">${icon(state.busy?'refresh':finished&&summary.success?'check':'tray')}</span>
      <button class="island-toggle" id="toggle" aria-label="${t(state.expanded?'collapse':'open')}" aria-expanded="${state.expanded}"><strong>${state.expanded?t('panelTitle'):status}</strong></button>
      ${state.expanded?`<div class="window-actions">${!empty?`<button class="icon-button" id="add" aria-label="${t('add')}" title="${t('add')}" ${state.busy?'disabled':''}>${icon('plus')}</button>`:''}<button class="icon-button" id="settings" aria-label="${t('settings')}" title="${t('settings')}">${icon('sliders')}</button><button class="icon-button" id="hide" aria-label="${t('collapse')}" title="${t('collapse')}">${icon('minus')}</button></div>`:`<span class="compact-indicator">${icon('plus')}</span>`}
    </header>
    ${state.expanded?`<div class="expanded-content">
      ${empty?`<div class="empty-state"><span class="drop-symbol" aria-hidden="true">${icon('tray')}</span><h1>${t('emptyTitle')}</h1><p>${t('idleSub')}</p><button class="secondary-button" id="pick">${t(native?'pick':'preview')}</button></div>`:`
        <div class="file-list" aria-label="${t('queue')}">${state.files.map(fileRow).join('')}</div>
        ${finished&&!showMotionOptions?`<div class="completion-row" role="status"><span>${t(summary.failed?(summary.success?'partialTitle':'failedTitle'):'doneTitle')}</span><span>${summary.success} ${t('success')}${summary.failed?` · ${summary.failed} ${t('failed')}`:''}</span></div>`:`
          <div class="format-row"><label for="format">${t('output')}</label><span class="format-control"><select id="format" ${!formats.length||state.busy?'disabled':''} aria-describedby="format-note">${formats.length?formats.map(format=>`<option value="${format}" ${state.format===format?'selected':''}>${t(format)}${format==='docx'?' (.docx)':''}</option>`).join(''):`<option>${t('selection')}</option>`}</select><span aria-hidden="true">${icon('down')}</span></span></div>
          <p class="format-note" id="format-note">${t(formats.length?note:'noFormats')}</p>${motion?motionControls():''}`}
        <div class="save-location" title="${t('destinationLabel')}: ${t('destination')}">${icon('folder')}<span>${t('destination')}</span></div>`}
      ${state.error?`<p class="error-banner" role="alert">${escape(message(state.error))}</p>`:''}
    </div>
    ${empty?`<footer class="empty-footer"><span>${native?icon('lock'):''}${t(native?'localFoot':'previewLabel')}</span>${native?'<kbd>⌘ O</kbd>':''}</footer>`:`
    <footer class="action-footer">
      ${state.busy?`<span class="progress-label"><span class="spinner"></span>${state.progress} / ${state.total}</span>`:`<button class="text-button neutral" id="${finished?'again':'clear'}">${t(finished?'done':'clear')}</button>`}
      <button class="primary-button" title="${!native?t('desktopOnly'):''}" id="${finished&&firstOutput?'reveal-primary':'convert'}" ${state.busy||(!firstOutput&&(!state.format||!native))?'disabled':''}>${finished&&firstOutput?icon('folder'):''}${finished&&firstOutput?t('reveal'):state.busy?t('busy'):finished?t('retry'):t('convert')}</button>
    </footer>
    ${state.busy?`<div class="progress" role="progressbar" aria-label="${t('busy')}" aria-valuemin="0" aria-valuenow="${state.progress}" aria-valuemax="${state.total||1}"><span style="width:${Math.round(state.progress/(state.total||1)*100)}%"></span></div>`:''}`}
    ${state.settings?settingsContent():''}
    ${state.drag?`<div class="drop-overlay"><span class="drop-symbol">${icon('tray')}</span><strong>${t('release')}</strong><span>${t('keep')}</span></div>`:''}`:''}
  </section>`;
  bind();
  if(state.settings){
    const dialog=$('#preferences-dialog');
    dialog.showModal();
    dialog.addEventListener('cancel',event=>{event.preventDefault();closeSettings();});
  }
  if (supportOpen && document.querySelector('.settings-content details')) document.querySelector('.settings-content details').open = true;
  for (const [selector, top] of scrollers) { const element=document.querySelector(selector); if(element)element.scrollTop=top; }
  if (focusedId) document.getElementById(focusedId)?.focus({preventScroll:true});
  syncLayout();
}

async function action(fn) {
  try { state.error=''; await fn(); }
  catch(error) {
    state.error=String(error?.message || error || t('error'));
    state.expanded=true;
    if(native) await invoke('set_expanded',{expanded:true}).catch(()=>{});
    render();
  }
}
async function choose() {
  if(state.busy) return;
  if(!native) {
    ingest(state.files.length ? [...state.files, {id:'demo-design',name:'Design.png',ext:'png',size:1835720,formats:['png','jpg','heic','tiff','bmp','gif','pdf'],error:null}].filter((f,i,a)=>a.findIndex(x=>x.id===f.id)===i) : [{id:'demo-motion',name:'Summer · Live Photo',ext:'livephoto',size:3624890,formats:['gif'],error:null}]);
    state.expanded=true; state.settings=false; render(); return;
  }
  state.picking=true;
  try { await invoke('choose_files'); await refresh(); }
  finally { state.picking=false; }
}
async function convert() {
  if(state.busy||!native||!state.format)return;
  state.remembered[family()]=state.format;savePrefs();
  state.busy=true;state.progress=0;state.total=state.files.length;state.results=[];render();
  try {state.results=await invoke('convert_files',{format:state.format,...(hasMotion(state.files)&&state.format==='gif'?{gifOptions:state.gifOptions}:{})});}
  finally {state.busy=false;}
  render();
}
let resizing=false;
let moving=false;
async function expand(expanded) {
  resizing=true;
  try {
    if(native) await invoke('set_expanded',{expanded});
    state.expanded=expanded;
    if(!expanded)state.settings=false;
    render();
  } finally { resizing=false; }
}
async function openSettings() {
  await expand(true);
  state.settings=true;render();
}
function closeSettings() { state.settings=false;render();$('#settings')?.focus({preventScroll:true}); }
function bind() {
  $('#toggle').onclick=()=>action(()=>expand(!state.expanded));
  $('#toggle').oncontextmenu=event=>{event.preventDefault();action(openSettings);};
  if($('#drag-handle'))$('#drag-handle').onpointerdown=event=>{
    if(native&&event.button===0){moving=true;getCurrentWindow().startDragging().catch(()=>{}).finally(()=>{moving=false;});}
  };
  if($('#pin'))$('#pin').onchange=()=>action(async()=>{await invoke('set_pinned',{pinned:!state.pinned}); await refresh();});
  if($('#park'))$('#park').onclick=()=>action(async()=>{await invoke('park_island');await expand(false);});
  if($('#quick'))$('#quick').onchange=event=>{state.quick=event.target.checked;savePrefs();};
  if($('#settings'))$('#settings').onclick=()=>action(openSettings);
  if($('#hide'))$('#hide').onclick=()=>action(()=>expand(false));
  ['add','empty-add','pick'].forEach(id=>{const button=$(`#${id}`);if(button)button.onclick=()=>action(choose);});
  document.querySelectorAll('[data-remove]').forEach(button=>button.onclick=()=>action(async()=>{
    if(native){await invoke('remove_file',{id:button.dataset.remove});await refresh();}
    else{ingest(state.files.filter(f=>f.id!==button.dataset.remove));render();}
  }));
  document.querySelectorAll('[data-reveal]').forEach(button=>button.onclick=()=>action(()=>invoke('reveal_output',{id:button.dataset.reveal})));
  for (const [id, key] of [['gif-size','maxDimension'],['gif-fps','fps']]) {
    if($(`#${id}`))$(`#${id}`).onchange=event=>{state.gifOptions[key]=Number(event.target.value);savePrefs();};
  }
  if($('#gif-loop'))$('#gif-loop').onchange=event=>{state.gifOptions.loop=event.target.checked;savePrefs();};
  if($('#format'))$('#format').onchange=event=>{state.format=event.target.value;render();$('#format')?.focus({preventScroll:true});};
  if($('#reveal-primary'))$('#reveal-primary').onclick=()=>action(()=>invoke('reveal_output',{id:state.results.find(result=>result.ok).id}));
  if($('#clear'))$('#clear').onclick=()=>action(async()=>{if(native)await invoke('clear_files');ingest([]);state.results=[];render();});
  if($('#convert'))$('#convert').onclick=()=>action(convert);
  if($('#again'))$('#again').onclick=()=>action(async()=>{if(native)await invoke('clear_files');ingest([]);state.results=[];state.expanded=false;if(native)await invoke('set_expanded',{expanded:false});render();});
  if($('#close-settings'))$('#close-settings').onclick=closeSettings;
  if($('#lang'))$('#lang').onchange=event=>{state.lang=event.target.value;savePrefs();render();};
  if($('#theme'))$('#theme').onchange=event=>{state.theme=event.target.value;savePrefs();render();};
}
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'){
    if(state.settings){event.preventDefault();closeSettings();}
    else if(state.expanded)action(()=>expand(false));
  }
  if((event.metaKey||event.ctrlKey)&&event.key==='o'){event.preventDefault();action(choose);}
  if((event.metaKey||event.ctrlKey)&&event.key===','){event.preventDefault();action(openSettings);}
});
// Preview accepts no files: only the native event bridge can grant file access.
document.addEventListener('dragover',event=>event.preventDefault());
document.addEventListener('drop',event=>event.preventDefault());
render();
if(native){
  action(async()=>{
    await listen('basket-files',event=>{
      const hadIds=new Set(state.files.map(f=>f.id));
      ingest(event.payload);state.expanded=true;state.settings=false;state.drag=false;render();
      const batch=state.files.map(f=>f.id).join(',');
      const remembered=quickFormat(state.files,hadIds,state);
      if(remembered&&batch!==autoBatch&&!state.busy){
        autoBatch=batch;state.format=remembered;action(convert);
      }
    });
    await listen('basket-drag',event=>{state.drag=Boolean(event.payload);render();});
    await listen('basket-error',event=>{state.error=String(event.payload);state.expanded=true;invoke('set_expanded',{expanded:true}).catch(()=>{});render();});
    await listen('basket-expanded',event=>{state.expanded=Boolean(event.payload);if(!state.expanded)state.settings=false;render();});
    await listen('basket-progress',event=>{state.progress=event.payload.done;state.total=event.payload.total;render();});
    await getCurrentWindow().onFocusChanged(({payload})=>{
      if(!payload&&state.expanded&&!state.picking&&!state.settings&&!state.drag&&!resizing&&!syncingLayout&&!moving)action(()=>expand(false));
    });
    await refresh();
    state.shortcut=await invoke('get_shortcut_status');
  });
}

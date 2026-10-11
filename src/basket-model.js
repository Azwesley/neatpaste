export const FORMAT_ORDER = ['png', 'jpg', 'pdf', 'heic', 'tiff', 'bmp', 'gif', 'txt', 'docx', 'md', 'rtf', 'html', 'csv', 'tsv', 'json'];

export function availableFormats(files) {
  const usable = files.filter(file => !file.error && file.formats?.length);
  return usable.length ? FORMAT_ORDER.filter(format => usable.every(file => file.formats.includes(format))) : [];
}

export function selectFormat(files, current) {
  const formats = availableFormats(files);
  if(formats.includes(current)) return current;
  const usable=files.filter(file=>!file.error);
  if(usable.length && usable.every(file=>file.ext==='pdf') && formats.includes('docx')) return 'docx';
  return formats[0] || null;
}

export function summarizeResults(files, results) {
  const ids = new Set(files.map(file => file.id));
  const relevant = results.filter(result => ids.has(result.id));
  return {
    success: relevant.filter(result => result.ok).length,
    failed: relevant.filter(result => !result.ok).length,
    pending: files.filter(file => !relevant.some(result => result.id === file.id)).length,
  };
}

export function fileSize(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '—';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

const IMAGE_TYPES = new Set(['png','jpg','jpeg','webp','heic','heif','tif','tiff','bmp','gif']);
const DATA_TYPES = new Set(['csv','tsv','json']);
const MOTION_TYPES = new Set(['mov','mp4','livephoto']);
export function hasMotion(files) {
  return files.some(file => !file.error && MOTION_TYPES.has(file.ext?.toLowerCase()));
}
export function gifOptions(preferences) {
  return {
    maxDimension: [320,480,640].includes(preferences?.maxDimension) ? preferences.maxDimension : 480,
    fps: [10,15,20].includes(preferences?.fps) ? preferences.fps : 15,
    loop: typeof preferences?.loop === 'boolean' ? preferences.loop : true,
  };
}
export function conversionFamily(files) {
  const types=new Set(files.filter(f=>!f.error).map(f=>MOTION_TYPES.has(f.ext?.toLowerCase())?'motion':IMAGE_TYPES.has(f.ext?.toLowerCase())?'image':f.ext==='pdf'?'pdf':DATA_TYPES.has(f.ext)?'data':'document'));
  return types.size===1?[...types][0]:'mixed';
}
export function quickFormat(files, previousIds, preferences) {
  if(!preferences.quick || !files.length || files.some(f=>f.error) || !files.some(f=>!previousIds.has(f.id)))return null;
  const format=preferences.remembered?.[conversionFamily(files)];
  return availableFormats(files).includes(format)?format:null;
}

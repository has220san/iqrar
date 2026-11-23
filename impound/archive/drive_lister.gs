/**
 * أداة جمع قائمة صور أرشيف الإيواء من Google Drive
 * ------------------------------------------------
 * لا تنقل ولا تعدّل أي صورة. تكتب فقط قائمة الملفات (الاسم، المعرّف، المجلد، التاريخ، الحجم)
 * في ورقة «قائمة الأرشيف» داخل جدول جديد، ليُستورد بعدها إلى نظام الإيواء.
 *
 * الاستخدام:
 * 1) افتح https://script.google.com ← New project، والصق هذا الملف كاملاً.
 * 2) اختر الدالة start من القائمة في الأعلى، ثم Run، ووافق على الصلاحيات.
 * 3) الأداة تعمل على دفعات (5 دقائق لكل دفعة) وتعود وحدها كل 10 دقائق حتى تنتهي.
 *    إذا توقفت (خطأ أو حدّ الاستخدام اليومي من Google) تكمل تلقائياً في الدورة التالية.
 *    لتحديث نسخة قديمة: الصق الملف الجديد مكان القديم، اختر resume ثم Run (لا تشغّل start).
 *    تابع التقدم من الرابط الذي يظهر في Execution log، أو من status.
 * 4) عند الانتهاء: File ← Download ← CSV من ورقة «قائمة الأرشيف».
 */

var ROOT_FOLDER_ID = '1iQC02dHJLugYavYYJdRwlilWvBLo8Q43';
var SHEET_NAME = 'قائمة الأرشيف';
var BATCH_MS = 5 * 60 * 1000;

function start() {
  var p = PropertiesService.getScriptProperties();
  p.deleteAllProperties();
  var ss = SpreadsheetApp.create('قائمة صور أرشيف الإيواء');
  var sh = ss.getSheets()[0];
  sh.setName(SHEET_NAME);
  sh.appendRow(['file_id', 'name', 'folder_path', 'mime', 'size', 'created', 'modified']);
  p.setProperties({
    sheetId: ss.getId(),
    queue: JSON.stringify([{ id: ROOT_FOLDER_ID, path: DriveApp.getFolderById(ROOT_FOLDER_ID).getName() }]),
    total: '0'
  });
  Logger.log('الجدول: ' + ss.getUrl());
  resume();
}

function resume() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return; // دفعة أخرى تعمل الآن
  try { run_(); } finally { lock.releaseLock(); }
}

function status() {
  var p = PropertiesService.getScriptProperties();
  Logger.log('الملفات حتى الآن: ' + p.getProperty('total') + ' | مجلدات متبقية: ' + JSON.parse(p.getProperty('queue') || '[]').length
    + (p.getProperty('done') ? ' | انتهى ✓' : ''));
}

function run_() {
  var t0 = Date.now();
  var p = PropertiesService.getScriptProperties();
  var sh = SpreadsheetApp.openById(p.getProperty('sheetId')).getSheetByName(SHEET_NAME);
  var queue = JSON.parse(p.getProperty('queue') || '[]');
  var total = Number(p.getProperty('total') || 0);
  if (p.getProperty('done')) { clearTriggers_(); Logger.log('انتهى ✓ عدد الملفات: ' + total); return; }
  ensureTrigger_(); // مؤقت دائم كل 10 دقائق، فلا تنقطع السلسلة إذا فشلت دفعة

  while (queue.length && Date.now() - t0 < BATCH_MS) {
    var cur = queue[0];
    var folder = DriveApp.getFolderById(cur.id);

    // المجلدات الفرعية تُضاف مرة واحدة فقط
    if (!cur.subsDone) {
      var subs = folder.getFolders();
      while (subs.hasNext()) { var s = subs.next(); queue.push({ id: s.getId(), path: cur.path + '/' + s.getName() }); }
      cur.subsDone = true;
    }

    var it = cur.token ? DriveApp.continueFileIterator(cur.token) : folder.getFiles();
    var rows = [];
    while (it.hasNext() && Date.now() - t0 < BATCH_MS) {
      var f = it.next();
      var mime = f.getMimeType();
      if (mime.indexOf('image/') !== 0 && mime !== 'application/pdf') continue;
      rows.push([f.getId(), f.getName(), cur.path, mime, f.getSize(), f.getDateCreated(), f.getLastUpdated()]);
      if (rows.length >= 500) { flush_(sh, rows); total += rows.length; rows = []; save_(p, queue, cur, it, total); }
    }
    if (rows.length) { flush_(sh, rows); total += rows.length; save_(p, queue, cur, it, total); }

    if (it.hasNext()) { cur.token = it.getContinuationToken(); break; }
    queue.shift();
  }

  p.setProperties({ queue: JSON.stringify(queue), total: String(total) });
  if (queue.length) {
    Logger.log('دفعة انتهت. الملفات حتى الآن: ' + total + '. تكمل تلقائياً خلال 10 دقائق.');
  } else {
    p.setProperty('done', '1');
    clearTriggers_();
    Logger.log('انتهى ✓ عدد الملفات: ' + total);
  }
}

function flush_(sh, rows) { sh.getRange(sh.getLastRow() + 1, 1, rows.length, rows[0].length).setValues(rows); }
// حفظ التقدم بعد كل كتابة، حتى لا يتكرر شيء إذا انقطعت الدفعة فجأة
function save_(p, queue, cur, it, total) {
  var more = it.hasNext();
  if (more) cur.token = it.getContinuationToken();
  p.setProperties({ queue: JSON.stringify(more ? queue : queue.slice(1)), total: String(total) });
}
function ensureTrigger_() {
  var p = PropertiesService.getScriptProperties();
  var id = p.getProperty('trigId');
  var ok = id && ScriptApp.getProjectTriggers().some(function (t) { return t.getUniqueId() === id; });
  if (ok) return;
  clearTriggers_();
  p.setProperty('trigId', ScriptApp.newTrigger('resume').timeBased().everyMinutes(10).create().getUniqueId());
}
function clearTriggers_() { ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'resume') ScriptApp.deleteTrigger(t); }); }

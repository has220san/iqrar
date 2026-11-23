/**
 * أداة جمع قائمة صور أرشيف الإيواء من Google Drive
 * ------------------------------------------------
 * لا تنقل ولا تعدّل أي صورة. تكتب فقط قائمة الملفات (الاسم، المعرّف، المجلد، التاريخ، الحجم)
 * في ورقة «قائمة الأرشيف» داخل جدول جديد، ليُستورد بعدها إلى نظام الإيواء.
 *
 * الاستخدام:
 * 1) افتح https://script.google.com ← New project، والصق هذا الملف كاملاً.
 * 2) اختر الدالة start من القائمة في الأعلى، ثم Run، ووافق على الصلاحيات.
 * 3) الأداة تعمل على دفعات (5 دقائق لكل دفعة) وتكمل وحدها كل دقيقة حتى تنتهي.
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
  run_();
}

function resume() { run_(); }

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
  clearTriggers_();

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
      if (rows.length >= 500) { flush_(sh, rows); total += rows.length; rows = []; }
    }
    if (rows.length) { flush_(sh, rows); total += rows.length; }

    if (it.hasNext()) { cur.token = it.getContinuationToken(); break; }
    queue.shift();
  }

  p.setProperties({ queue: JSON.stringify(queue), total: String(total) });
  if (queue.length) {
    ScriptApp.newTrigger('resume').timeBased().after(60 * 1000).create();
    Logger.log('دفعة انتهت. الملفات حتى الآن: ' + total + '. تكمل تلقائياً بعد دقيقة.');
  } else {
    p.setProperty('done', '1');
    Logger.log('انتهى ✓ عدد الملفات: ' + total);
  }
}

function flush_(sh, rows) { sh.getRange(sh.getLastRow() + 1, 1, rows.length, rows[0].length).setValues(rows); }
function clearTriggers_() { ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'resume') ScriptApp.deleteTrigger(t); }); }

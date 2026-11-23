-- =====================================================================
-- ينشئ ملف «أرشيف قديم» لكل لوحة في قائمة الدرايف، ويربط صورها به.
-- قبل التنفيذ: نفّذ 003_archive_drive.sql، ثم استورد CSV أداة الدرايف إلى جدول imp_archive_files
-- (Table Editor ← imp_archive_files ← Insert ← Import data from CSV).
-- آمن لإعادة التنفيذ: لا يكرر الملفات ولا الصور.
-- =====================================================================
with parsed as (
  select f.*, public.imp_plate_from_name(f.name) as plate,
         nullif(f.created,'')::timestamptz as created_at
  from public.imp_archive_files f
  where not exists (select 1 from public.imp_photos ph where ph.drive_id = f.file_id)
),
plates as (
  select public.imp_norm_plate(plate) as plate_key, min(plate) as plate, min(created_at) as first_at, max(created_at) as last_at
  from parsed where plate <> '' group by 1
)
insert into public.imp_vehicles(plate, plate_key, site, status, entry_at, exit_at, created_by, notes, legacy)
select p.plate, p.plate_key, 'archive', 7, p.first_at, p.last_at, 'drive-archive', 'من أرشيف صور الدرايف',
       jsonb_build_object('source','drive-archive')
from plates p
where not exists (select 1 from public.imp_vehicles v where v.plate_key = p.plate_key and v.site = 'archive');

insert into public.imp_photos(vehicle_id, kind, path, drive_id, doc_type, source_name, note, created_at)
select v.id, 'archive', 'drive:' || f.file_id, f.file_id, public.imp_doc_type(f.name || ' ' || coalesce(f.folder_path,'')),
       f.name, coalesce(f.folder_path,''), coalesce(nullif(f.created,'')::timestamptz, now())
from public.imp_archive_files f
join public.imp_vehicles v on v.site = 'archive'
  and v.plate_key = public.imp_norm_plate(public.imp_plate_from_name(f.name))
where public.imp_plate_from_name(f.name) <> ''
  and not exists (select 1 from public.imp_photos ph where ph.drive_id = f.file_id);

-- صور بلا لوحة في اسمها لكن فيها رقم إيواء معروف (مثل «السحب 76013») تُربط بملف تلك المركبة
insert into public.imp_photos(vehicle_id, kind, path, drive_id, doc_type, source_name, note, created_at)
select distinct on (f.file_id) v.id, 'archive', 'drive:' || f.file_id, f.file_id,
       public.imp_doc_type(f.name || ' ' || coalesce(f.folder_path,'')), f.name, coalesce(f.folder_path,''),
       coalesce(nullif(f.created,'')::timestamptz, now())
from public.imp_archive_files f
join public.imp_vehicles v on v.impound_no <> '' and v.impound_no = any (
       select (regexp_matches(f.name, '(\d{4,6})', 'g'))[1])
where public.imp_plate_from_name(f.name) = ''
  and not exists (select 1 from public.imp_photos ph where ph.drive_id = f.file_id)
order by f.file_id, v.id desc;

-- النتيجة
select
  (select count(*) from public.imp_archive_files) as files_listed,
  (select count(*) from public.imp_photos where drive_id is not null) as photos_linked,
  (select count(*) from public.imp_vehicles where site = 'archive') as archive_vehicles,
  (select count(distinct a.plate_key) from public.imp_vehicles a join public.imp_vehicles c
     on c.plate_key = a.plate_key and c.site <> 'archive' where a.site = 'archive') as also_in_current_log,
  (select count(*) from public.imp_archive_unmatched) as without_plate;

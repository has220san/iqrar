-- =====================================================================
-- أرشيف الصور القديم من Google Drive (الصور تبقى في الدرايف، والنظام يحفظ روابطها)
-- يُنفَّذ مرة واحدة بعد 001. آمن لإعادة التنفيذ.
-- =====================================================================

insert into public.imp_sites(code,name,active,sort) values ('archive','أرشيف قديم (الدرايف)',false,10)
on conflict (code) do nothing;

alter table public.imp_photos add column if not exists drive_id  text;
alter table public.imp_photos add column if not exists doc_type  text not null default '';
alter table public.imp_photos add column if not exists source_name text not null default '';
alter table public.imp_photos alter column taken_by drop not null;
alter table public.imp_photos drop constraint if exists imp_photos_kind_check;
alter table public.imp_photos add constraint imp_photos_kind_check check (kind in
  ('police_doc','front','back','right','left','vin','parking','belongings','transfer_out','transfer_in','archive'));
create unique index if not exists imp_photos_drive on public.imp_photos(drive_id) where drive_id is not null;

-- جدول مؤقت تُستورد إليه قائمة الملفات (CSV من أداة الدرايف). كل الأعمدة نصية.
create table if not exists public.imp_archive_files (
  file_id     text primary key,
  name        text,
  folder_path text,
  mime        text,
  size        text,
  created     text,
  modified    text
);
alter table public.imp_archive_files enable row level security;

-- يستخرج اللوحة من اسم الملف: «د ص م 9155 (3).jpg» أو «4385 أ ط ى.jpg» أو «اطلاق كيا ح ب ا 9035.jpeg»
create or replace function public.imp_plate_from_name(p text) returns text
language plpgsql immutable as $$
declare s text; m text[]; d text;
begin
  s := translate(coalesce(p,''), E'‪‫‬‭‮‎‏', '');
  s := regexp_replace(s, '\.(jpe?g|png|heic|webp|pdf)(\.jpe?g)?$', '', 'i');
  s := regexp_replace(s, '\(\d+\)', ' ', 'g');
  s := translate(s, 'أإآيةـ', 'اااىه');
  s := regexp_replace(s, '([^\d\s])(\d)', '\1 \2', 'g');      -- «4538المخدرات» ← فصل الأرقام عن الحروف
  s := regexp_replace(s, '(\d)([^\d\s])', '\1 \2', 'g');
  s := ' ' || regexp_replace(s, '\s+', ' ', 'g') || ' ';
  m := regexp_match(s, ' ([ء-ى]) ([ء-ى]) ([ء-ى]) ');
  if m is null then m := regexp_match(s, ' ([ء-ى]) ([ء-ى]) '); end if;
  if m is null then return ''; end if;
  d := (regexp_match(s, ' (\d{1,4}) '))[1];
  if d is null then return ''; end if;
  return array_to_string(m, ' ') || ' ' || d;
end $$;

create or replace function public.imp_doc_type(p text) returns text
language sql immutable as $$
  select case
    when p ~ 'اطلاق|إطلاق' then 'إطلاق'
    when p ~ 'هوية|هويه' then 'هوية'
    when p ~ 'برنت|استمارة|استماره' then 'استمارة'
    when p ~ 'مبايعة|مبايعه|عقد' then 'مبايعة/عقد'
    when p ~ 'السحب|سحب' then 'سحب'
    when p ~ 'ايواء|إيواء' then 'إيواء'
    else '' end
$$;

-- عرض: ملفات لم تُستخرج منها لوحة (للمراجعة اليدوية)
create or replace view public.imp_archive_unmatched as
  select f.* from public.imp_archive_files f
  where public.imp_plate_from_name(f.name) = ''
    and not exists (select 1 from public.imp_photos ph where ph.drive_id = f.file_id);
revoke all on public.imp_archive_unmatched from anon, authenticated;

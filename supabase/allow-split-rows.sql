-- ESP32 2대가 행을 따로 보내도록 허용 (2026-11-12)
--   ESP32 #1 → {"PH","EC"}만,  ESP32 #2 → {"온도","습도"}만 INSERT
--   지금은 "PH"(아마 "EC"도) 가 NOT NULL 이라 #2의 온습도 행이 400(23502)으로 거부됨.
-- Supabase → SQL Editor 에 붙여넣고 Run. (데이터는 안 지워짐, 제약만 풀림)

alter table public.sensor_data alter column "PH"  drop not null;
alter table public.sensor_data alter column "EC"  drop not null;
alter table public.sensor_data alter column "온도" drop not null;
alter table public.sensor_data alter column "습도" drop not null;

notify pgrst, 'reload schema';

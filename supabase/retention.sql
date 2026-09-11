-- ============================================================
-- retention.sql : 1년 추이용 일별 요약(sensor_daily) + 30일 지난 raw 정리
--
-- 실행 전 준비:
--   Supabase 대시보드 > Database > Extensions 에서 pg_cron 켜기
--
-- 여러 번 실행해도 안전 (create ... if not exists / or replace / cron.schedule 재등록).
-- 데이터가 어느 정도 쌓인 뒤 실행해도 되고, 지금 실행해도 됨(10분 뒤부터 오늘치 채워짐).
-- ============================================================

-- ------------------------------------------------------------
-- 1) 일별 평균 요약 테이블  (대시보드 "최근 1년" 모드 소스)
--    raw 를 30일만 보관해도 여기엔 1년+ 치가 계속 남는다.
-- ------------------------------------------------------------
create table if not exists public.sensor_daily (
  day       date primary key,
  ph        numeric,
  ec        numeric,
  temp      numeric,
  humidity  numeric,
  samples   int
);

grant select on public.sensor_daily to anon;

drop policy if exists "Public can read sensor daily" on public.sensor_daily;
alter table public.sensor_daily enable row level security;
create policy "Public can read sensor daily"
  on public.sensor_daily for select to anon using (true);

-- ------------------------------------------------------------
-- 2) 최근 3일치 일별 평균을 upsert
--    (늦게 들어온 데이터 + 오늘 진행 중인 하루까지 매번 갱신)
--    날짜 경계는 한국시간 기준.
-- ------------------------------------------------------------
create or replace function public.refresh_sensor_daily()
returns void language plpgsql as $$
begin
  insert into public.sensor_daily (day, ph, ec, temp, humidity, samples)
  select (created_at at time zone 'Asia/Seoul')::date,
         round(avg("PH")::numeric, 2),
         round(avg("EC")::numeric, 2),
         round(avg("온도")::numeric, 1),
         round(avg("습도")::numeric, 1),
         count(*)
  from public.sensor_data
  where created_at >= now() - interval '3 days'
  group by 1
  on conflict (day) do update set
    ph = excluded.ph, ec = excluded.ec, temp = excluded.temp,
    humidity = excluded.humidity, samples = excluded.samples;
end $$;

-- ------------------------------------------------------------
-- 3) 30일 지난 raw 삭제 (삭제 전에 그 구간도 한 번 더 요약해서 유실 방지)
-- ------------------------------------------------------------
create or replace function public.prune_sensor_data()
returns void language plpgsql as $$
begin
  insert into public.sensor_daily (day, ph, ec, temp, humidity, samples)
  select (created_at at time zone 'Asia/Seoul')::date,
         round(avg("PH")::numeric, 2),
         round(avg("EC")::numeric, 2),
         round(avg("온도")::numeric, 1),
         round(avg("습도")::numeric, 1),
         count(*)
  from public.sensor_data
  where created_at < now() - interval '30 days'
  group by 1
  on conflict (day) do nothing;

  delete from public.sensor_data
  where created_at < now() - interval '30 days';
end $$;

-- ------------------------------------------------------------
-- 4) 스케줄 등록
--    - 요약: 10분마다
--    - raw 정리: 매일 18:00 UTC = 03:00 KST (트래픽 적은 시간)
--    cron 표현식은 UTC 기준.
-- ------------------------------------------------------------
select cron.unschedule('sensor-daily-refresh')
  where exists (select 1 from cron.job where jobname = 'sensor-daily-refresh');
select cron.unschedule('sensor-data-prune')
  where exists (select 1 from cron.job where jobname = 'sensor-data-prune');

select cron.schedule('sensor-daily-refresh', '*/10 * * * *',
                     $$select public.refresh_sensor_daily()$$);
select cron.schedule('sensor-data-prune', '0 18 * * *',
                     $$select public.prune_sensor_data()$$);

-- 지금 바로 한 번 채우고 싶으면:
--   select public.refresh_sensor_daily();

-- 등록된 크론 확인:
--   select jobname, schedule, command from cron.job;

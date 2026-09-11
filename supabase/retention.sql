-- ============================================================
-- retention.sql : 3단 피라미드 저장 구조
--   실시간(raw, 3일) → 5분 평균(계속 보관) → 일별 평균(계속 보관)
--
-- "최근 7일" 모드의 sensor_5min 을 뷰(조회 때마다 raw 전체 재집계)에서
-- 테이블(cron이 미리 계산)로 교체 — 방문자 조회 비용이 방문 빈도와 무관하게 항상 쌈.
--
-- 실행 전: Supabase 대시보드 > Database > Extensions 에서 pg_cron 켜기.
-- 여러 번 실행해도 안전 (기존에 enable-public-read.sql 로 만든 뷰가 있어도
-- 0번에서 자동으로 정리하고 테이블로 교체함).
-- ============================================================

-- 0) 예전 뷰 정리 (enable-public-read.sql 구버전에서 만들었던 것)
drop view if exists public.sensor_5min cascade;

-- ------------------------------------------------------------
-- 1) 5분 평균 테이블  (대시보드 "최근 7일" 모드 소스)
-- ------------------------------------------------------------
create table if not exists public.sensor_5min (
  bucket    timestamptz primary key,
  ph        numeric,
  ec        numeric,
  temp      numeric,
  humidity  numeric,
  samples   int
);

alter table public.sensor_5min enable row level security;
drop policy if exists "Public can read sensor 5min" on public.sensor_5min;
create policy "Public can read sensor 5min"
  on public.sensor_5min for select to anon using (true);

create or replace function public.refresh_sensor_5min()
returns void language plpgsql as $$
begin
  insert into public.sensor_5min (bucket, ph, ec, temp, humidity, samples)
  select date_bin('5 minutes', created_at, timestamptz '2000-01-01'),
         round(avg("PH")::numeric, 2),
         round(avg("EC")::numeric, 2),
         round(avg("온도")::numeric, 1),
         round(avg("습도")::numeric, 1),
         count(*)
  from public.sensor_data
  where created_at >= now() - interval '1 day'   -- 최근 하루치만 다시 계산 (버퍼)
  group by 1
  on conflict (bucket) do update set
    ph = excluded.ph, ec = excluded.ec, temp = excluded.temp,
    humidity = excluded.humidity, samples = excluded.samples;
end $$;

-- ------------------------------------------------------------
-- 2) 일별 평균 테이블  (대시보드 "최근 1년" 모드 소스)
-- ------------------------------------------------------------
create table if not exists public.sensor_daily (
  day       date primary key,
  ph        numeric,
  ec        numeric,
  temp      numeric,
  humidity  numeric,
  samples   int
);

alter table public.sensor_daily enable row level security;
drop policy if exists "Public can read sensor daily" on public.sensor_daily;
create policy "Public can read sensor daily"
  on public.sensor_daily for select to anon using (true);

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
  where created_at >= now() - interval '3 days'  -- 최근 3일치 다시 계산 (버퍼)
  group by 1
  on conflict (day) do update set
    ph = excluded.ph, ec = excluded.ec, temp = excluded.temp,
    humidity = excluded.humidity, samples = excluded.samples;
end $$;

-- ------------------------------------------------------------
-- 3) raw 정리
--    이제 5분/일별 테이블이 역사를 계속 들고 있으므로, raw는
--    "실시간" 모드(최근 30분)와 위 두 롤업의 버퍼(최대 3일)만 있으면 됨.
--    삭제 전 안전망으로 두 롤업을 한 번 더 강제 실행.
-- ------------------------------------------------------------
create or replace function public.prune_sensor_data()
returns void language plpgsql as $$
begin
  perform public.refresh_sensor_5min();
  perform public.refresh_sensor_daily();

  delete from public.sensor_data
  where created_at < now() - interval '3 days';
end $$;

-- ------------------------------------------------------------
-- 4) 스케줄 등록 (cron 표현식은 UTC 기준)
--    - 5분 평균 갱신: 5분마다
--    - 일별 평균 갱신: 10분마다
--    - raw 정리: 매일 18:00 UTC = 03:00 KST
-- ------------------------------------------------------------
select cron.unschedule(jobname)
  from cron.job
  where jobname in ('sensor-5min-refresh', 'sensor-daily-refresh', 'sensor-data-prune');

select cron.schedule('sensor-5min-refresh', '*/5 * * * *',
                     $$select public.refresh_sensor_5min()$$);
select cron.schedule('sensor-daily-refresh', '*/10 * * * *',
                     $$select public.refresh_sensor_daily()$$);
select cron.schedule('sensor-data-prune', '0 18 * * *',
                     $$select public.prune_sensor_data()$$);

-- 지금 바로 한 번 채우기 (10분/5분 기다리지 않고 바로 데이터 뜨게)
select public.refresh_sensor_5min();
select public.refresh_sensor_daily();

-- PostgREST 스키마 캐시 새로고침
notify pgrst, 'reload schema';

-- 등록된 크론 확인:
--   select jobname, schedule, command from cron.job;
-- 각 테이블 상태 확인:
--   select count(*) from public.sensor_5min;
--   select count(*) from public.sensor_daily;
--   select count(*) from public.sensor_data;

import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_FRONTEND_DIR = path.resolve(BACKEND_DIR, '..', 'event-earth-demo');
const DEFAULT_MIGRATION = path.join(
  BACKEND_DIR,
  'supabase',
  'migrations',
  '202608110002_import_historical_events.sql',
);

const PERSON_CONFIG = Object.freeze({
  ayanga: { databaseId: 'ayg', displayName: '阿云嘎', siteId: 'ayg' },
  zhengyunlong: { databaseId: 'zyl', displayName: '郑云龙', siteId: 'zyl' },
});

const UUID_URL_NAMESPACE = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

function argumentValue(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const frontendDir = path.resolve(argumentValue('--frontend', DEFAULT_FRONTEND_DIR));
const migrationPath = path.resolve(argumentValue('--migration', DEFAULT_MIGRATION));
const mappingPath = path.join(frontendDir, 'core', 'data', 'communityEventIds.js');
const reportPath = path.join(BACKEND_DIR, 'reports', 'history-import.json');
const checkOnly = process.argv.includes('--check');

function normalize(value) {
  return String(value ?? '')
    .normalize('NFKC')
    .trim()
    .replace(/\s+/g, '')
    .replace(/[·•・]/g, '·')
    .toLocaleLowerCase('zh-CN');
}

function uuidToBytes(uuid) {
  return Buffer.from(uuid.replaceAll('-', ''), 'hex');
}

function uuidV5(name, namespace = UUID_URL_NAMESPACE) {
  const hash = createHash('sha1')
    .update(Buffer.concat([uuidToBytes(namespace), Buffer.from(name, 'utf8')]))
    .digest()
    .subarray(0, 16);
  hash[6] = (hash[6] & 0x0f) | 0x50;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  const hex = hash.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function shortHash(value, length = 16) {
  return createHash('sha256').update(value).digest('hex').slice(0, length);
}

function sqlString(value) {
  if (value === null || value === undefined || value === '') return 'null';
  return `'${String(value).replaceAll("'", "''")}'`;
}

function sqlJson(value) {
  return `${sqlString(JSON.stringify(value))}::jsonb`;
}

function sqlNumber(value) {
  return Number.isFinite(Number(value)) ? String(Number(value)) : 'null';
}

function unique(values) {
  return [...new Set(values.filter((value) => value !== null && value !== undefined && value !== ''))];
}

function isKnownDate(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(value ?? '');
}

function eventKey(event) {
  return [event.date, normalize(event.title), normalize(event.city)].join('|');
}

function chooseText(records, field, { avoidUnknown = false } = {}) {
  const candidates = unique(records.map((record) => String(record[field] ?? '').trim()));
  const preferred = avoidUnknown
    ? candidates.filter((value) => !/(未公开|未检得|待核|未知|未确认)/.test(value))
    : candidates;
  return [...(preferred.length ? preferred : candidates)].sort((a, b) => b.length - a.length || a.localeCompare(b, 'zh-CN'))[0] ?? '';
}

function firstCoordinate(records, field) {
  const record = records.find((item) => Number.isFinite(Number(item[field])));
  return record ? Number(record[field]) : null;
}

function timestampFor(date) {
  return isKnownDate(date) ? `${date}T12:00:00+08:00` : null;
}

function sourceRecord(personId, event) {
  const config = PERSON_CONFIG[personId];
  return {
    ...event,
    _personId: personId,
    _databasePersonId: config.databaseId,
    _displayName: config.displayName,
    _siteId: config.siteId,
  };
}

async function loadSourceEvents() {
  const sourceFiles = {
    ayanga: path.join(frontendDir, 'core', 'data', 'artists', 'ayanga.js'),
    zhengyunlong: path.join(frontendDir, 'core', 'data', 'artists', 'zhengyunlong.js'),
  };
  for (const filePath of Object.values(sourceFiles)) {
    if (!existsSync(filePath)) throw new Error(`找不到历史活动文件：${filePath}`);
  }
  const loaded = [];
  for (const [personId, filePath] of Object.entries(sourceFiles)) {
    const module = await import(`${pathToFileURL(filePath).href}?history-import=${Date.now()}`);
    for (const event of module.events ?? []) loaded.push(sourceRecord(personId, event));
  }
  return loaded;
}

function buildCatalogue(sourceEvents) {
  const skipped = sourceEvents
    .filter((event) => !isKnownDate(event.date))
    .map((event) => ({
      legacyId: event.id,
      personId: event._personId,
      title: event.title,
      dateLabel: event.dateLabel,
      reason: 'missing_exact_date',
    }));

  const grouped = new Map();
  for (const event of sourceEvents.filter((item) => isKnownDate(item.date))) {
    const key = eventKey(event);
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(event);
  }

  const venues = new Map();
  const events = [];
  const eventSites = new Map();
  const eventPeople = new Map();
  const mapping = {};

  for (const [key, records] of [...grouped.entries()].sort(([a], [b]) => a.localeCompare(b, 'zh-CN'))) {
    const eventId = uuidV5(`musical-community:event:${key}`);
    const title = chooseText(records, 'title');
    const city = chooseText(records, 'city');
    const country = chooseText(records, 'country');
    const venueName = chooseText(records, 'venue', { avoidUnknown: true });
    const venueKey = [normalize(country), normalize(city), normalize(venueName)].join('|');
    const venueId = venueName ? uuidV5(`musical-community:venue:${venueKey}`) : null;
    const latitude = firstCoordinate(records, 'lat');
    const longitude = firstCoordinate(records, 'lon');
    const endDates = records.map((record) => record.endDate).filter(isKnownDate).sort();
    const descriptions = unique(records.map((record) => record.description));
    const description = records.length > 1
      ? unique(records.map((record) => record.description && `${record._displayName}：${record.description}`)).join('\n')
      : descriptions[0] ?? '';
    const sourceUrls = unique(records.flatMap((record) => record.sourceUrls ?? []));
    const metadata = {
      import_source: 'event-earth-demo',
      import_version: 1,
      legacy_ids: records.map((record) => record.id),
      artists: unique(records.map((record) => record._databasePersonId)),
      roles: Object.fromEntries(records.map((record) => [record._databasePersonId, record.role || record.duty || 'performer'])),
      duties: Object.fromEntries(records.filter((record) => record.duty).map((record) => [record._databasePersonId, record.duty])),
      date_labels: unique(records.map((record) => record.dateLabel)),
      tour_batches: unique(records.map((record) => record.tourBatch)),
      tour_summaries: unique(records.map((record) => record.tourSummary)),
      source_urls: sourceUrls,
      media_urls: unique(records.flatMap((record) => record.mediaUrls ?? [])),
      sessions: records.map((record) => ({ person_id: record._databasePersonId, sessions: record.sessions ?? [] })),
    };

    if (venueId && !venues.has(venueId)) {
      venues.set(venueId, { id: venueId, name: venueName, city, country, latitude, longitude });
    }

    events.push({
      id: eventId,
      slug: `history-${records[0].date}-${shortHash(key, 16)}`,
      title,
      category: chooseText(records, 'category'),
      startTime: timestampFor(records[0].date),
      endTime: timestampFor(endDates.at(-1)),
      venueId,
      city,
      country,
      latitude,
      longitude,
      description: description.slice(0, 10000),
      sourceUrl: sourceUrls.find((url) => /^https?:\/\//i.test(url)) ?? null,
      metadata,
    });

    for (const record of records) {
      mapping[record.id] = eventId;
      for (const siteId of ['duo', record._siteId]) {
        eventSites.set(`${eventId}|${siteId}`, { eventId, siteId });
      }
      eventPeople.set(`${eventId}|${record._databasePersonId}`, {
        eventId,
        personId: record._databasePersonId,
        role: 'performer',
      });
    }
  }

  return {
    sourceEvents,
    skipped,
    venues: [...venues.values()],
    events,
    eventSites: [...eventSites.values()],
    eventPeople: [...eventPeople.values()],
    mapping: Object.fromEntries(Object.entries(mapping).sort(([a], [b]) => a.localeCompare(b))),
  };
}

function valuesSql(rows, renderRow) {
  return rows.map((row) => `  (${renderRow(row)})`).join(',\n');
}

function buildMigration(catalogue) {
  const venueValues = valuesSql(catalogue.venues, (venue) => [
    sqlString(venue.id), sqlString(venue.name), sqlString(venue.city), sqlString(venue.country),
    sqlNumber(venue.latitude), sqlNumber(venue.longitude),
  ].join(', '));
  const eventValues = valuesSql(catalogue.events, (event) => [
    sqlString(event.id), sqlString(event.slug), sqlString(event.title), sqlString(event.category),
    sqlString(event.startTime), sqlString(event.endTime), sqlString(event.venueId), sqlString(event.city),
    sqlString(event.country), sqlNumber(event.latitude), sqlNumber(event.longitude), sqlString(event.description),
    sqlString(event.sourceUrl), "'published'", sqlJson(event.metadata),
  ].join(', '));
  const siteValues = valuesSql(catalogue.eventSites, (relation) => `${sqlString(relation.eventId)}, ${sqlString(relation.siteId)}`);
  const peopleValues = valuesSql(catalogue.eventPeople, (relation) => `${sqlString(relation.eventId)}, ${sqlString(relation.personId)}, ${sqlString(relation.role)}`);

  return `-- Generated by scripts/generate-history-import.mjs. Do not edit by hand.
-- Source records: ${catalogue.sourceEvents.length}; imported events: ${catalogue.events.length}; skipped without exact date: ${catalogue.skipped.length}.

begin;

alter table public.events
  add column if not exists metadata jsonb not null default '{}'::jsonb
  check (jsonb_typeof(metadata) = 'object');

insert into public.sites (id, name, base_url, status)
values
  ('ayg', '阿云嘎个人站', 'https://aygmusical.ranyechai.site', 'active'),
  ('zyl', '郑云龙个人站', 'https://zyldl.ranyechai.site', 'active'),
  ('duo', '双人站', 'https://musical.ranyechai.site', 'active')
on conflict (id) do update set
  name = excluded.name,
  base_url = excluded.base_url,
  status = excluded.status;

insert into public.persons (id, display_name, metadata)
values
  ('ayg', '阿云嘎', '{"site_id":"ayg"}'::jsonb),
  ('zyl', '郑云龙', '{"site_id":"zyl"}'::jsonb)
on conflict (id) do update set
  display_name = excluded.display_name,
  metadata = excluded.metadata;

insert into public.venues (id, name, city, country, latitude, longitude)
values
${venueValues}
on conflict (id) do update set
  name = excluded.name,
  city = excluded.city,
  country = excluded.country,
  latitude = excluded.latitude,
  longitude = excluded.longitude;

insert into public.events (
  id, slug, title, category, start_time, end_time, venue_id, city, country,
  latitude, longitude, description, source_url, status, metadata
)
values
${eventValues}
on conflict (id) do update set
  slug = excluded.slug,
  title = excluded.title,
  category = excluded.category,
  start_time = excluded.start_time,
  end_time = excluded.end_time,
  venue_id = excluded.venue_id,
  city = excluded.city,
  country = excluded.country,
  latitude = excluded.latitude,
  longitude = excluded.longitude,
  description = excluded.description,
  source_url = excluded.source_url,
  status = excluded.status,
  metadata = excluded.metadata;

insert into public.event_sites (event_id, site_id)
values
${siteValues}
on conflict (event_id, site_id) do nothing;

insert into public.event_people (event_id, person_id, role)
values
${peopleValues}
on conflict (event_id, person_id, role) do nothing;

do $$
declare
  imported_event_count integer;
  imported_site_count integer;
  imported_people_count integer;
  missing_duo_count integer;
begin
  select count(*) into imported_event_count
  from public.events
  where metadata @> '{"import_source":"event-earth-demo","import_version":1}'::jsonb;

  select count(*) into imported_site_count
  from public.event_sites es
  join public.events e on e.id = es.event_id
  where e.metadata @> '{"import_source":"event-earth-demo","import_version":1}'::jsonb;

  select count(*) into imported_people_count
  from public.event_people ep
  join public.events e on e.id = ep.event_id
  where e.metadata @> '{"import_source":"event-earth-demo","import_version":1}'::jsonb;

  select count(*) into missing_duo_count
  from public.events e
  where e.metadata @> '{"import_source":"event-earth-demo","import_version":1}'::jsonb
    and not exists (
      select 1 from public.event_sites es where es.event_id = e.id and es.site_id = 'duo'
    );

  if imported_event_count <> ${catalogue.events.length}
    or imported_site_count <> ${catalogue.eventSites.length}
    or imported_people_count <> ${catalogue.eventPeople.length}
    or missing_duo_count <> 0 then
    raise exception 'historical import verification failed: events=%, sites=%, people=%, missing_duo=%',
      imported_event_count, imported_site_count, imported_people_count, missing_duo_count;
  end if;
end;
$$;

commit;
`;
}

function buildMappingModule(mapping) {
  return `// Generated by backend/scripts/generate-history-import.mjs. Do not edit by hand.\nexport const communityEventIds = Object.freeze(${JSON.stringify(mapping, null, 2)});\n\nexport function communityIdFor(legacyEventId) {\n  return communityEventIds[legacyEventId] ?? null;\n}\n`;
}

function buildReport(catalogue) {
  const sharedEvents = catalogue.events.filter((event) => event.metadata.artists.length > 1);
  return {
    generatedAt: new Date().toISOString(),
    frontendDir,
    migrationPath,
    counts: {
      sourceRecords: catalogue.sourceEvents.length,
      sourceAyanga: catalogue.sourceEvents.filter((event) => event._personId === 'ayanga').length,
      sourceZhengYunlong: catalogue.sourceEvents.filter((event) => event._personId === 'zhengyunlong').length,
      importedEvents: catalogue.events.length,
      venues: catalogue.venues.length,
      eventSites: catalogue.eventSites.length,
      eventPeople: catalogue.eventPeople.length,
      mappedLegacyIds: Object.keys(catalogue.mapping).length,
      sharedEvents: sharedEvents.length,
      skipped: catalogue.skipped.length,
    },
    sharedEvents: sharedEvents.map((event) => ({ id: event.id, title: event.title, startTime: event.startTime, legacyIds: event.metadata.legacy_ids })),
    skipped: catalogue.skipped,
  };
}

async function checkFile(filePath, expected) {
  if (!existsSync(filePath)) throw new Error(`缺少生成文件：${filePath}`);
  const actual = await readFile(filePath, 'utf8');
  if (actual !== expected) throw new Error(`生成文件已过期，请重新运行生成命令：${filePath}`);
}

const sourceEvents = await loadSourceEvents();
const catalogue = buildCatalogue(sourceEvents);
const migration = buildMigration(catalogue);
const mappingModule = buildMappingModule(catalogue.mapping);
const report = buildReport(catalogue);

if (checkOnly) {
  await checkFile(migrationPath, migration);
  await checkFile(mappingPath, mappingModule);
  console.log(`历史活动生成文件有效：${catalogue.events.length} 个活动，${Object.keys(catalogue.mapping).length} 个前端映射。`);
} else {
  await mkdir(path.dirname(migrationPath), { recursive: true });
  await mkdir(path.dirname(mappingPath), { recursive: true });
  await mkdir(path.dirname(reportPath), { recursive: true });
  await writeFile(migrationPath, migration, 'utf8');
  await writeFile(mappingPath, mappingModule, 'utf8');
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(report.counts, null, 2));
  console.log(`迁移：${migrationPath}`);
  console.log(`映射：${mappingPath}`);
  console.log(`报告：${reportPath}`);
}

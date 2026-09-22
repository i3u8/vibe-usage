export const QUOTA_SCHEMA_VERSION = 1;

export const QUOTA_PRODUCT_IDS = Object.freeze([
  'kimi-code',
  'zcode',
  'grok',
  'opencode-go',
  'cursor',
]);

export const FETCHABLE_QUOTA_PRODUCT_IDS = Object.freeze([
  'kimi-code',
  'zcode',
  'grok',
  'opencode-go',
]);

const FETCH_STATUSES = new Set([
  'ok',
  'no_data',
  'missing_credentials',
  'expired_credentials',
  'unauthorized',
  'retryable_error',
  'unsupported',
]);

function finiteNumber(value, name) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new TypeError(`${name} must be a finite number`);
  }
  return value;
}

function optionalISODate(value, name) {
  if (value === undefined || value === null) return undefined;
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new TypeError(`${name} must be an ISO date string`);
  }
  return date.toISOString();
}

export function normalizeMeter(raw, index = 0) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new TypeError(`meters[${index}] must be an object`);
  }
  const id = String(raw.id || '').trim();
  const label = String(raw.label || '').trim();
  if (!id || !label) throw new TypeError(`meters[${index}] needs id and label`);

  const utilization = Math.max(0, Math.min(100,
    finiteNumber(raw.utilization, `meters[${index}].utilization`)));
  const meter = { id, label, utilization };
  const resetsAt = optionalISODate(raw.resetsAt, `meters[${index}].resetsAt`);
  if (resetsAt) meter.resetsAt = resetsAt;
  if (raw.windowSeconds !== undefined && raw.windowSeconds !== null) {
    const seconds = finiteNumber(raw.windowSeconds, `meters[${index}].windowSeconds`);
    if (seconds > 0) meter.windowSeconds = seconds;
  }
  return meter;
}

export function quotaResult({
  id,
  status,
  meters = [],
  planLabel,
  fetchedAt = new Date(),
  dataAsOf = fetchedAt,
  message,
  source = 'live',
}) {
  if (!FETCHABLE_QUOTA_PRODUCT_IDS.includes(id)) {
    throw new TypeError(`unsupported quota product: ${id}`);
  }
  if (!FETCH_STATUSES.has(status)) {
    throw new TypeError(`invalid quota status: ${status}`);
  }
  const result = {
    id,
    status,
    meters: meters.map(normalizeMeter),
    fetchedAt: new Date(fetchedAt).toISOString(),
    source,
  };
  const normalizedDataAsOf = optionalISODate(dataAsOf, 'dataAsOf');
  if (normalizedDataAsOf) result.dataAsOf = normalizedDataAsOf;
  if (typeof planLabel === 'string' && planLabel.trim()) result.planLabel = planLabel.trim();
  if (typeof message === 'string' && message.trim()) result.message = message.trim();
  return result;
}

export function quotaEnvelope(products) {
  return { schemaVersion: QUOTA_SCHEMA_VERSION, products };
}

const buckets = new Map<string, number[]>();
export function allowCheckoutAttempt(key: string, now = Date.now()): boolean {
  const windowStart = now - 60_000;
  const recent = (buckets.get(key) ?? []).filter((time) => time > windowStart);
  if (recent.length >= 5) return false;
  recent.push(now); buckets.set(key, recent); return true;
}

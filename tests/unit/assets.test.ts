import { existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

describe('official production assets', () => {
  it.each(['brand/recorrido-wordmark.png', 'brand/recorrido-mark.png', 'brand/favicon.png', 'media/hero.mp4', 'media/hero-poster.webp'])('%s exists and is non-empty', (file) => {
    const path = join(process.cwd(), 'public', file);
    expect(existsSync(path)).toBe(true);
    expect(statSync(path).size).toBeGreaterThan(100);
  });
});

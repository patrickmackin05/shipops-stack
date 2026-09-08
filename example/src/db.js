import pg from 'pg';
import { createClient } from 'redis';

const { Pool } = pg;

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on('error', (err) => {
  console.error(JSON.stringify({ level: 'error', msg: 'idle pg client error', err: err.message }));
});

let redis = null;

export async function getRedis() {
  if (!process.env.REDIS_URL) return null;
  if (redis?.isOpen) return redis;

  redis = createClient({ url: process.env.REDIS_URL });
  redis.on('error', (err) => {
    console.error(JSON.stringify({ level: 'error', msg: 'redis error', err: err.message }));
  });
  await redis.connect();
  return redis;
}

export async function closeAll() {
  if (redis?.isOpen) await redis.quit();
  await pool.end();
}

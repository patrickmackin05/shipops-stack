import express from 'express';
import { pool, getRedis, closeAll } from './db.js';
import { migrate } from './migrate.js';

const app = express();
const PORT = Number(process.env.PORT ?? 3000);
const CACHE_TTL = 30; // seconds

app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));
app.use(express.static('public'));

// --- health ---------------------------------------------------------------
// /healthz is the liveness probe used by Docker, Caddy and deploy.sh. It must
// stay cheap and must genuinely touch the database - a health check that only
// proves Node is running will happily report green through a dead DB.
app.get('/healthz', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({
      status: 'ok',
      version: process.env.APP_VERSION ?? 'dev',
      uptime: Math.round(process.uptime()),
    });
  } catch (err) {
    res.status(503).json({ status: 'degraded', error: err.message });
  }
});

// --- api ------------------------------------------------------------------
app.get('/api/links', async (_req, res, next) => {
  try {
    const redis = await getRedis();
    if (redis) {
      const cached = await redis.get('links:recent');
      if (cached) return res.type('json').set('x-cache', 'hit').send(cached);
    }

    const { rows } = await pool.query(
      'SELECT id, url, title, clicks, created_at FROM links ORDER BY created_at DESC LIMIT 100',
    );
    const body = JSON.stringify(rows);
    if (redis) await redis.setEx('links:recent', CACHE_TTL, body);
    res.type('json').set('x-cache', 'miss').send(body);
  } catch (err) {
    next(err);
  }
});

app.post('/api/links', async (req, res, next) => {
  try {
    const { url, title } = req.body ?? {};
    if (typeof url !== 'string' || !/^https?:\/\/\S+$/i.test(url)) {
      return res.status(400).json({ error: 'url must be a valid http(s) URL' });
    }

    const { rows } = await pool.query(
      'INSERT INTO links (url, title) VALUES ($1, $2) RETURNING id, url, title, clicks, created_at',
      [url, typeof title === 'string' ? title.slice(0, 200) : ''],
    );

    const redis = await getRedis();
    if (redis) await redis.del('links:recent');
    res.status(201).json(rows[0]);
  } catch (err) {
    next(err);
  }
});

app.delete('/api/links/:id', async (req, res, next) => {
  try {
    const { rowCount } = await pool.query('DELETE FROM links WHERE id = $1', [req.params.id]);
    if (rowCount === 0) return res.status(404).json({ error: 'not found' });
    const redis = await getRedis();
    if (redis) await redis.del('links:recent');
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

// --- errors ---------------------------------------------------------------
app.use((err, _req, res, _next) => {
  console.error(JSON.stringify({ level: 'error', msg: 'unhandled', err: err.message }));
  res.status(500).json({ error: 'internal error' });
});

// --- lifecycle ------------------------------------------------------------
// Migrations run at boot rather than as a separate deploy step so that a
// rolling restart can never leave new code running against an old schema.
const server = await (async () => {
  await migrate();
  return app.listen(PORT, '0.0.0.0', () => {
    console.log(JSON.stringify({ level: 'info', msg: 'listening', port: PORT }));
  });
})();

// Graceful shutdown matters for zero-downtime deploys: Docker sends SIGTERM
// and we must drain in-flight requests before the old container exits.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal }));
    server.close(async () => {
      await closeAll();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  });
}

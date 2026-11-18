import { PostgresStore } from '@mastra/pg';

export const pStore = new PostgresStore({
  id: 'postiz-store',
  connectionString: process.env.DATABASE_URL!,
  ...(process.env.MASTRA_PG_MAX_CONNS
    ? { max: Number(process.env.MASTRA_PG_MAX_CONNS) }
    : {}),
  ...(process.env.DATABASE_SSL_NO_VERIFY === 'true'
    ? { ssl: { rejectUnauthorized: false } }
    : {}),
});

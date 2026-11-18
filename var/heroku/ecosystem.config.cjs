module.exports = {
  apps: [
    {
      name: 'backend',
      cwd: '/app/apps/backend',
      script: './dist/apps/backend/src/main.js',
      node_args: '--max-old-space-size=320 --experimental-require-module',
      env: {
        NODE_ENV: 'production',
        PORT: '3000',
      },
      autorestart: true,
      max_memory_restart: '380M',
    },
    {
      name: 'frontend',
      cwd: '/app/apps/frontend',
      script: '/app/node_modules/next/dist/bin/next',
      args: 'start -p 4200',
      node_args: '--max-old-space-size=256',
      env: {
        NODE_ENV: 'production',
        PORT: '4200',
      },
      autorestart: true,
      max_memory_restart: '320M',
    },
    {
      name: 'orchestrator',
      cwd: '/app/apps/orchestrator',
      script: './dist/apps/orchestrator/src/main.js',
      node_args: '--max-old-space-size=320 --experimental-require-module',
      env: {
        NODE_ENV: 'production',
        ORCHESTRATOR_PORT: '3002',
      },
      autorestart: true,
      max_memory_restart: '380M',
    },
  ],
};

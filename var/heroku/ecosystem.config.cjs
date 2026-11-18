module.exports = {
  apps: [
    {
      name: 'backend',
      cwd: '/app/apps/backend',
      script: './dist/apps/backend/src/main.js',
      node_args: '--max-old-space-size=640 --experimental-require-module',
      env: {
        NODE_ENV: 'production',
        PORT: '3000',
      },
      autorestart: true,
    },
    {
      name: 'frontend',
      cwd: '/app/apps/frontend',
      script: '/app/node_modules/next/dist/bin/next',
      args: 'start -p 4200',
      node_args: '--max-old-space-size=384',
      env: {
        NODE_ENV: 'production',
        PORT: '4200',
      },
      autorestart: true,
    },
    {
      name: 'orchestrator',
      cwd: '/app/apps/orchestrator',
      script: './dist/apps/orchestrator/src/main.js',
      node_args: '--max-old-space-size=512 --experimental-require-module',
      env: {
        NODE_ENV: 'production',
        ORCHESTRATOR_PORT: '3002',
        TEMPORAL_WORKFLOW_BUNDLE_PATH: '/app/apps/orchestrator/dist/workflow-bundle.js',
      },
      autorestart: true,
    },
  ],
};

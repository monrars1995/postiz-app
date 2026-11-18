import ts from 'typescript';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { bundleWorkflowCode } from '@temporalio/worker';

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');

const aliases = {
  '@gitroom/backend/': 'apps/backend/src/',
  '@gitroom/frontend/': 'apps/frontend/src/',
  '@gitroom/helpers/': 'libraries/helpers/src/',
  '@gitroom/nestjs-libraries/': 'libraries/nestjs-libraries/src/',
  '@gitroom/react/': 'libraries/react-shared-libraries/src/',
  '@gitroom/plugins/': 'libraries/plugins/src/',
  '@gitroom/orchestrator/': 'apps/orchestrator/src/',
  '@gitroom/extension/': 'apps/extension/src/',
};

function rewriteSpec(spec, fromOutFile, outRoot) {
  for (const [prefix, targetPrefix] of Object.entries(aliases)) {
    if (spec.startsWith(prefix)) {
      const targetOut = path.join(outRoot, targetPrefix, spec.slice(prefix.length));
      let rel = path.relative(path.dirname(fromOutFile), targetOut).replace(/\\/g, '/');
      if (!rel.startsWith('.')) rel = './' + rel;
      return rel;
    }
  }
  return spec;
}

function makeAliasTransformer(fromOutFile, outRoot) {
  return (context) => {
    const visit = (node) => {
      if (
        ts.isCallExpression(node) &&
        ts.isIdentifier(node.expression) &&
        node.expression.text === 'require' &&
        node.arguments.length === 1 &&
        ts.isStringLiteral(node.arguments[0])
      ) {
        const next = rewriteSpec(node.arguments[0].text, fromOutFile, outRoot);
        if (next !== node.arguments[0].text) {
          return ts.factory.updateCallExpression(node, node.expression, node.typeArguments, [
            ts.factory.createStringLiteral(next),
          ]);
        }
      }
      if (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier)) {
        const next = rewriteSpec(node.moduleSpecifier.text, fromOutFile, outRoot);
        if (next !== node.moduleSpecifier.text) {
          return ts.factory.updateImportDeclaration(
            node,
            node.modifiers,
            node.importClause,
            ts.factory.createStringLiteral(next),
            node.attributes
          );
        }
      }
      if (ts.isExportDeclaration(node) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
        const next = rewriteSpec(node.moduleSpecifier.text, fromOutFile, outRoot);
        if (next !== node.moduleSpecifier.text) {
          return ts.factory.updateExportDeclaration(
            node,
            node.modifiers,
            node.isTypeOnly,
            node.exportClause,
            ts.factory.createStringLiteral(next),
            node.attributes
          );
        }
      }
      return ts.visitEachChild(node, visit, context);
    };
    return (sf) => ts.visitNode(sf, visit);
  };
}

function compileTree(dirs, outRoot) {
  fs.rmSync(outRoot, { recursive: true, force: true });
  let count = 0;

  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === 'node_modules' || entry.name === 'dist' || entry.name === 'test') continue;
        walk(full);
      } else if (
        /\.(ts|tsx)$/.test(entry.name) &&
        !/\.d\.ts$/.test(entry.name) &&
        !/\.spec\.(ts|tsx)$/.test(entry.name)
      ) {
        const rel = path.relative(repoRoot, full);
        const outJs = path.join(outRoot, rel.replace(/\.(ts|tsx)$/, '.js'));
        const src = fs.readFileSync(full, 'utf8');
        const res = ts.transpileModule(src, {
          fileName: full,
          compilerOptions: {
            module: ts.ModuleKind.CommonJS,
            target: ts.ScriptTarget.ES2021,
            experimentalDecorators: true,
            emitDecoratorMetadata: true,
            esModuleInterop: true,
            allowSyntheticDefaultImports: true,
            jsx: ts.JsxEmit.ReactJSX,
            sourceMap: false,
          },
          transformers: {
            before: [makeAliasTransformer(outJs, outRoot)],
          },
        });
        fs.mkdirSync(path.dirname(outJs), { recursive: true });
        fs.writeFileSync(outJs, res.outputText);
        count++;
      } else if (entry.name.endsWith('.json')) {
        const rel = path.relative(repoRoot, full);
        const outJson = path.join(outRoot, rel);
        fs.mkdirSync(path.dirname(outJson), { recursive: true });
        fs.copyFileSync(full, outJson);
      }
    }
  };

  for (const d of dirs) {
    walk(path.join(repoRoot, d));
  }
  return count;
}

const sourceDirs = [
  'apps/backend/src',
  'apps/orchestrator/src',
  'libraries/helpers/src',
  'libraries/nestjs-libraries/src',
];

const backendDist = path.join(repoRoot, 'apps/backend/dist');
const orchestratorDist = path.join(repoRoot, 'apps/orchestrator/dist');

console.log('[build-nest] Transpiling server & orchestrator sources...');
const total = compileTree(sourceDirs, backendDist);
fs.rmSync(orchestratorDist, { recursive: true, force: true });
fs.cpSync(backendDist, orchestratorDist, { recursive: true });

console.log('[build-nest] Pre-bundling Temporal workflows...');
const workflowEntry = require.resolve(
  path.join(orchestratorDist, 'apps/orchestrator/src/workflows')
);
const { code } = await bundleWorkflowCode({ workflowsPath: workflowEntry });
const bundleOut = path.join(orchestratorDist, 'workflow-bundle.js');
fs.writeFileSync(bundleOut, code);

console.log(
  `[build-nest] Compiled ${total} files + workflow bundle (${Math.round(
    code.length / 1024
  )} KB, peak RSS: ${Math.round(process.memoryUsage().rss / 1024 / 1024)} MB)`
);

// Preloaded only by the host-matrix tests. Run the production dispatcher and
// package scripts on the local filesystem; replace only SDK executables.
import cp from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const probe = fileURLToPath(new URL('./sdk-command.mjs', import.meta.url));
if (process.argv[1] !== probe) {
  Object.defineProperty(process, 'platform', {value: process.env.FIXTURE_PLATFORM});
  Object.defineProperty(process, 'arch', {value: process.env.FIXTURE_ARCH});
  for (const name of ['spawn', 'spawnSync']) {
    const original = cp[name];
    cp[name] = (file, args, options) => /^(?:cjc|cjpm|fixture-cc)(?:\.exe)?$/.test(path.basename(file))
      ? original(process.execPath, [probe, file, ...args], options)
      : original(file, args, options);
  }
  syncBuiltinESMExports();
}

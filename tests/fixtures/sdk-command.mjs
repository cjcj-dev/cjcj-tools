import fs from 'node:fs';
import path from 'node:path';

const [file, ...args] = process.argv.slice(2);
const {PATH, LD_LIBRARY_PATH, DYLD_LIBRARY_PATH, CANGJIE_HOME} = process.env;
fs.appendFileSync(process.env.FIXTURE_RECORD, JSON.stringify({
  file, args, cwd: process.cwd(), PATH, LD_LIBRARY_PATH, DYLD_LIBRARY_PATH, CANGJIE_HOME
})+'\n');
if (process.env.FIXTURE_SUCCESS === 'cjpm') {
  const out = path.join(args[args.indexOf('--target-dir')+1], 'release/bin/main');
  fs.mkdirSync(path.dirname(out), {recursive:true});
  fs.writeFileSync(out, 'fixture executable');
} else if (!(process.env.FIXTURE_SUCCESS === 'cjc' && path.basename(file) === 'cjc')) {
  process.exitCode = 73;
}

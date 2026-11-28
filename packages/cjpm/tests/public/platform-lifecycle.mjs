// Linux consumer suite. Run with a native SDK that includes x86_64 Windows
// cross inputs for the optional --windows cases.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const [executable, destination, option] = process.argv.slice(2);
assert(executable && destination && (option === undefined || option === '--windows'),
    'usage: node platform-lifecycle.mjs <cjpm> <fresh-directory> [--windows]');
const cjpm = path.resolve(executable);
const work = path.resolve(destination);
fs.mkdirSync(work);
const logs = path.join(work, 'logs');
fs.mkdirSync(logs);
const checks = [], commands = [];
const save = () => fs.writeFileSync(path.join(logs, 'results.json'), JSON.stringify({checks, commands}, null, 2));
function check(name, fn) {
    try {
        fn();
        checks.push({name, pass: true});
    } catch (error) {
        checks.push({name, pass: false, error: error.stack});
        process.exitCode = 1;
    } finally {
        save();
    }
}
function run(name, cwd, argv, rc = 0) {
    const r = spawnSync(argv[0], argv.slice(1), {cwd, encoding: 'utf8', timeout: 90_000, maxBuffer: 8 << 20});
    commands.push({name, argv, cwd, rc: r.status, signal: r.signal, error: r.error?.message});
    fs.writeFileSync(path.join(logs, name + '.stdout'), r.stdout ?? '');
    fs.writeFileSync(path.join(logs, name + '.stderr'), r.stderr ?? '');
    save();
    assert.ifError(r.error);
    assert.equal(r.signal, null);
    assert.equal(r.status, rc, name);
    return (r.stdout ?? '') + (r.stderr ?? '');
}
function write(file, body) {
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(file, body);
}
function project(dir, name, body, config = '', output = 'executable') {
    write(path.join(dir, 'cjpm.toml'),
        `[package]\nname = "${name}"\nversion = "1.0.0"\ncjc-version = "1.0.0"\noutput-type = "${output}"\n` + config);
    write(path.join(dir, 'src/main.cj'), `package ${name}\n` + body);
    return dir;
}

const build = [cjpm, 'build', '-V', '-j', '2'];
const test = [cjpm, 'test', '-V', '-j', '2'];
const simple = 'main(): Int64 { println("PURE_HOST"); return 0 }\n';
const profile = '\n[profile.build]\nperformance_analysis = true\n';
const stats = ['time_cost.json', 'memory_cost.json', 'package_command.json'];

check('pure-host', () => {
    const dir = project(path.join(work, 'pure'), 'pure', simple);
    run('pure-build', dir, build);
    assert.match(run('pure-run', dir, [path.join(dir, 'target/release/bin/main')]), /PURE_HOST/);
});
check('native-c', () => {
    const dir = project(path.join(work, 'native'), 'nativeapp',
        'foreign func c_fixture_value(): Int64\nmain(): Int64 { println(unsafe { c_fixture_value() }); return 0 }\n',
        '\n[ffi.c]\nfixture.path = "./native"\n');
    write(path.join(dir, 'native/value.c'), 'long long c_fixture_value(void) { return 73; }\n');
    run('native-cc', dir, ['cc', '-c', 'native/value.c', '-o', 'native/value.o']);
    run('native-ar', dir, ['ar', 'rcs', 'native/libfixture.a', 'native/value.o']);
    assert.match(run('native-build', dir, build), /-lfixture\b/);
    assert.equal(run('native-run', dir, [path.join(dir, 'target/release/bin/main')]).trim(), '73');
});
check('profile-directory-rejected', () => {
    const dir = project(path.join(work, 'profile-file'), 'profilefile', simple, profile);
    const blocked = path.join(dir, 'target/release/performance_analysis');
    write(blocked, 'keep this file');
    const result = run('profile-file-build', dir, build, 1);
    assert.match(result, /failed to create .*performance_analysis.* directory/);
    assert.equal(fs.readFileSync(blocked, 'utf8'), 'keep this file');
    assert(!/time_cost\.json|memory_cost\.json|package_command\.json/.test(result), 'no statistics write attempted');
    for (const name of stats) assert(!fs.existsSync(path.join(dir, name)));
});
check('profile-validation-returns-original-error', () => {
    const dir = project(path.join(work, 'profile-early'), 'profileearly', simple, profile + 'cjc-jobs = 0\n');
    const result = run('profile-early-build', dir, build, 1);
    assert.match(result, /cjc-jobs.*positive integer/);
    assert.doesNotMatch(result, /An exception has occurred|IllegalArgumentException/);
    assert.match(result, /Error: cjpm build failed/);
    assert(!/time_cost\.json|memory_cost\.json|package_command\.json/.test(result));
    for (const name of stats) assert(!fs.existsSync(path.join(dir, name)), name);
});
check('profile-success-writes-statistics', () => {
    const dir = project(path.join(work, 'profile-good'), 'profilegood', simple, profile);
    run('profile-good-build', dir, build);
    for (const name of stats) {
        const data = JSON.parse(fs.readFileSync(path.join(dir, 'target/release/performance_analysis', name), 'utf8'));
        assert(Object.keys(data).length > 0, name);
    }
});

const workspace = path.join(work, 'workspace');
write(path.join(workspace, 'cjpm.toml'), '[workspace]\nmembers = ["member", "peer"]\ntest-members = ["peer"]\n');
const member = project(path.join(workspace, 'member'), 'member', simple);
const peer = project(path.join(workspace, 'peer'), 'peer', 'public func value(): Int64 { 11 }\n', '', 'static');
write(path.join(peer, 'src/value_test.cj'),
    'package peer\nimport std.unittest.*\nimport std.unittest.testmacro.*\n@Test\nfunc workspacePeer(): Unit { @Expect(value(), 11) }\n');
check('workspace-root', () => {
    assert.match(run('workspace-root-test', workspace, test), /workspacePeer/);
});
check('workspace-from-member', () => {
    const prefix = path.join(work, 'installed');
    run('workspace-member-install', member,
        [cjpm, 'install', '--path', workspace, '--root', prefix, '-m', 'member', '-j', '2']);
    assert.match(run('workspace-member-run', member, [path.join(prefix, 'bin/member')]), /PURE_HOST/);
});
check('workspace-rejects-non-member', () => {
    const bad = path.join(work, 'workspace-bad');
    write(path.join(bad, 'cjpm.toml'), '[workspace]\nmembers = ["one"]\ntest-members = ["other"]\n');
    project(path.join(bad, 'one'), 'one', simple);
    fs.mkdirSync(path.join(bad, 'other'));
    assert.match(run('workspace-bad-test', bad, test, 1), /must appear in the members field/);
});

const hostTriple = 'x86_64-unknown-linux-gnu';
const windowsTriple = 'x86_64-w64-mingw32';
const archive = (name, target) => {
    const dir = path.join(work, name, 'choice');
    const file = path.join(work, name, 'source/choice.cj');
    write(file, `package choice\npublic func choiceValue(): Int64 { ${target ? 29 : 17} }\n`);
    fs.mkdirSync(dir);
    run(name + '-compile', path.dirname(dir), ['cjc', ...(target ? ['--target=' + target] : []),
        '--output-type=staticlib', '-p', 'source', '--output-dir', dir, '-o', 'libchoice.a']);
    assert(fs.existsSync(path.join(dir, 'choice.cjo')));
    return dir;
};
const binDeps = (triple, dir) => `\n[target.${triple}.bin-dependencies]\npath-option = [${JSON.stringify(dir)}]\n`;
const binBody = 'import choice.*\nmain(): Int64 { println(choiceValue()); return 0 }\n';
const testBody = 'import choice.*\npublic func buildValue(): Int64 { choiceValue() }\n';
const checkLink = (output, selected, excluded) => {
    const lines = output.split('\n').filter(line => /-lchoice\b/.test(line));
    assert(lines.length > 0, 'no compiler link invocation consumed choice');
    for (const line of lines) {
        assert(line.includes(selected), line);
        // Only a library search argument is forbidden. Import search is a separate concern.
        assert(!line.includes('-L ' + excluded) && !line.includes('-L=' + excluded) &&
            !line.includes('-L "' + excluded) && !line.includes("-L '" + excluded), line);
    }
};

let host, target;
check('host-binary', () => {
    host = archive('host-choice');
    const dir = project(path.join(work, 'bin-host'), 'binhost', binBody, binDeps(hostTriple, host));
    checkLink(run('bin-host-build', dir, build), host, 'unused-target-library');
    assert.equal(run('bin-host-run', dir, [path.join(dir, 'target/release/bin/main')]).trim(), '17');
});

if (option === '--windows') {
    check('cross-build-binary', () => {
        target = archive('windows-choice', windowsTriple);
        const dir = project(path.join(work, 'bin-cross'), 'bincross', binBody,
            binDeps(hostTriple, host) + binDeps(windowsTriple, target));
        checkLink(run('bin-cross-build', dir, [...build, '--target', windowsTriple]), target, host);
        const output = path.join(dir, 'target', windowsTriple, 'release/bin/main.exe');
        assert.match(run('bin-cross-artifact', dir, ['file', output]), /PE32\+/);
    });
    check('host-macro-in-cross-build', () => {
        const dir = project(path.join(work, 'bin-macro'), 'binmacro',
            'import binmacro.hostmacro.*\nmain(): Int64 { println(@UseHost(31)); return 0 }\n',
            binDeps(hostTriple, host) + binDeps(windowsTriple, target));
        write(path.join(dir, 'src/hostmacro/macro.cj'),
            'macro package binmacro.hostmacro\nimport std.ast.*\nimport choice.*\n' +
            'public macro UseHost(input: Tokens): Tokens {\n' +
            '    if (choiceValue() != 17) { throw Exception("wrong platform archive") }\n' +
            '    return input\n}\n');
        const output = run('bin-macro-build', dir, [...build, '--target', windowsTriple]);
        const lines = output.split('\n').filter(line => line.includes('--compile-macro'));
        assert(lines.length > 0, 'host macro compiler did not run');
        checkLink(lines.join('\n'), host, target);
        assert(lines.every(line => !line.includes('--target=' + windowsTriple)), lines.join('\n'));
    });
    check('cross-test-binary', () => {
        const dir = project(path.join(work, 'bin-cross-test'), 'bintest', testBody,
            binDeps(hostTriple, host) + binDeps(windowsTriple, target), 'static');
        write(path.join(dir, 'src/main_test.cj'),
            'package bintest\nimport std.unittest.*\nimport std.unittest.testmacro.*\n@Test\nfunc fromBinary(): Unit { @Expect(buildValue(), 29) }\n');
        checkLink(run('bin-cross-test', dir, [...test, '--no-run', '--target', windowsTriple]), target, host);
    });
}

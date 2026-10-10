/**
 * Removes `@FastNative` from the Kotlin bindings nitrogen generates under
 * nitrogen/generated/android, and the import it leaves unused. Run it after
 * every nitrogen run: `npm run nitro-codegen` does both, and so must any
 * consumer script that regenerates this library's bindings.
 * android/build.gradle fails the build while a generated file still has the
 * annotation.
 *
 * Why: nitrogen (0.35) marks the JNI method behind every generated callback
 * class (Func_*.kt, `private external fun invoke_cxx`) @FastNative. That
 * method runs the callback's C++ std::function: the dispatcher of a JS
 * callback, or a C++ consumer's own code. Android's documentation of
 * dalvik.annotation.optimization.FastNative: the garbage collector cannot
 * suspend a thread while it executes a @FastNative method, so such a method
 * must not block or acquire native locks that can be held for a long time.
 * A C++ callback is free to take its own mutex, and then:
 *   1. The manager's thread delivers a callback through invoke_cxx; the C++
 *      callback waits for mutex M.
 *   2. Another thread holds M and calls into Java (any method of the
 *      manager, or any other JNI call) while a garbage collection starts.
 *   3. The collector's suspend-all waits for the first thread, which waits for
 *      M, whose holder waits at its suspend point for the collector.
 * Neither ever resumes, and every other thread of the app stops at its next
 * suspend point: the process hangs. Without the annotation the JNI call moves
 * the calling thread into the native state the collector does not wait for,
 * so the collection finishes and the lock holder goes on. The cost is a
 * regular JNI transition per callback.
 *
 * Fails, without writing anything, when the generated output isn't what it
 * expects: no bindings, no Func_*.kt, or a FastNative it doesn't know how to
 * remove. A nitrogen change then breaks this step loudly instead of letting
 * the annotation back in.
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const libraryRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const generatedAndroid = join(libraryRoot, 'nitrogen', 'generated', 'android');

// The two forms nitrogen emits: the annotation on its own line above
// `private external fun invoke_cxx`, and its import.
const annotationLine = /^[ \t]*@FastNative[ \t]*\r?\n/gm;
const importLine = /^import dalvik\.annotation\.optimization\.FastNative[ \t]*\r?\n/gm;

function fail(message) {
  console.error(`strip-fast-native: ${message}`);
  process.exit(1);
}

function kotlinFiles(dir) {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) files.push(...kotlinFiles(path));
    else if (entry.isFile() && entry.name.endsWith('.kt')) files.push(path);
  }
  return files;
}

const shown = (path) => relative(libraryRoot, path);

if (!existsSync(generatedAndroid)) {
  fail(`${shown(generatedAndroid)} doesn't exist: run nitrogen first`);
}
const files = kotlinFiles(generatedAndroid);
if (!files.some((file) => /^Func_.+\.kt$/.test(basename(file)))) {
  fail(
    `no generated callback class (Func_*.kt) under ${shown(generatedAndroid)}: ` +
      "nitrogen's output layout changed; find where it emits @FastNative now and update this script",
  );
}

const edits = [];
for (const file of files) {
  const source = readFileSync(file, 'utf8');
  if (!source.includes('FastNative')) continue;
  const stripped = source.replace(annotationLine, '').replace(importLine, '');
  if (stripped.includes('FastNative')) {
    fail(
      `${shown(file)} still mentions FastNative in a form this script doesn't remove ` +
        '(it expects "@FastNative" on its own line and "import dalvik.annotation.optimization.FastNative"); update this script',
    );
  }
  edits.push([file, stripped]);
}
// Written only after every file passed, so a failure leaves nitrogen's output untouched.
for (const [file, stripped] of edits) writeFileSync(file, stripped);

console.log(`strip-fast-native: removed @FastNative from ${edits.length} of ${files.length} generated Kotlin files`);

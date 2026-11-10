#!/usr/bin/env node
// Check out the libraries this tree builds with, at the commits lib.lock.json pins (about 900 MB, with their own
// submodules). Needs git and network access. A library already present is left as it is.
//
//   node script/libs.js
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

const tree = path.resolve(__dirname, '..');
const git = (args) => execFileSync('git', args, {cwd: tree, stdio: 'inherit'});
for (const lib of JSON.parse(fs.readFileSync(path.join(tree, 'lib.lock.json'), 'utf8')).libraries) {
  const to = path.join(tree, lib.path);
  if (fs.existsSync(to) && fs.readdirSync(to).length) {
    console.log(`${lib.path}: present`);
    continue;
  }
  console.log(`${lib.path}: ${lib.url} at ${lib.commit}`);
  git(['clone', '--quiet', lib.url, to]);
  git(['-C', to, 'checkout', '--quiet', lib.commit]);
  git(['-C', to, 'submodule', 'update', '--init', '--recursive', '--quiet']);
}

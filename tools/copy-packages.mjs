import fs from "node:fs";
import path from "node:path";

const manifest = (folder) => JSON.parse(fs.readFileSync(path.join(folder, "package.json"), "utf8"));

function locate(name, from, root) {
  for (let at = from; at.startsWith(root); at = path.dirname(at)) {
    const candidate = path.join(at, "node_modules", name);
    if (fs.existsSync(path.join(candidate, "package.json"))) return candidate;
  }
  return null;
}

/**
 * Copies each named package and everything it depends on from `root`'s node_modules into `out`, keeping
 * their paths, so a folder runs with exactly the versions that were tested. Returns the count and size.
 */
export function copyPackages(names, root, out, { peers = [] } = {}) {
  const copied = new Set();
  const copy = (folder) => {
    if (copied.has(folder)) return;
    copied.add(folder);
    const { dependencies = {}, optionalDependencies = {}, peerDependencies = {} } = manifest(folder);
    fs.cpSync(folder, path.join(out, path.relative(root, folder)), { recursive: true, dereference: true, filter: (source) => !source.slice(folder.length).includes("/node_modules/") && !source.endsWith(".map") });
    for (const name of Object.keys({ ...dependencies, ...optionalDependencies })) {
      const found = locate(name, folder, root);
      if (found) copy(found);
    }
    for (const name of Object.keys(peerDependencies).filter((each) => peers.includes(each))) {
      const found = locate(name, folder, root);
      if (found) copy(found);
    }
  };
  for (const name of names) copy(path.join(root, "node_modules", name));
  return { count: copied.size, megabytes: Math.round(size(out) / 1e6) };
}

const size = (folder) => fs.readdirSync(folder, { withFileTypes: true }).reduce((sum, entry) => sum + (entry.isDirectory() ? size(path.join(folder, entry.name)) : fs.statSync(path.join(folder, entry.name)).size), 0);

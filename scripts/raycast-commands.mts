// Turns raycast-catalog.json (exported from the app by `spacetile-catalog`) into one no-view Raycast
// command per Spacetile command in Settings → Keys, so each gets Raycast's alias and hotkey fields.
// Run through `app/scripts/raycast-generate`; it lives outside raycast/ so the extension, which the
// Raycast Store builds on its own, carries only the generated sources.
import { readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

interface Entry {
  name: string;
  command: string;
  title: string;
  icon?: string;
}

const [dir, catalogPath] = process.argv.slice(2);
if (!dir || !catalogPath) {
  console.error("usage: node raycast-commands.mts <Raycast extension dir> <catalog.json>");
  process.exit(64);
}

/** Hand-written commands, kept as they are. */
const manual = new Set(["run-command"]);
const header = "// Generated from catalog.json by Spacetile's app/scripts/raycast-generate; don't edit.";

/** Minor words kept lower case, except as the first or last word. */
const minorWords = new Set(
  "a an the and but or nor for yet so to as at by from in into of off on onto out over up with".split(" "),
);
/**
 * The app's titles are sentence case; the Store wants title case, hyphenated parts included. A
 * trailing particle is capitalised, so "Pop out" becomes "Pop Out".
 */
const raycastTitle = (title: string) =>
  title
    .split(" ")
    .map((word, i, words) =>
      i > 0 && i < words.length - 1 && minorWords.has(word.toLowerCase())
        ? word.toLowerCase()
        : word.replace(
            /(^\P{L}*|[-/])(\p{Ll})/gu,
            (_, separator: string, letter: string) => separator + letter.toUpperCase(),
          ),
    )
    .join(" ");

const sections: { title: string; actions: Entry[] }[] = JSON.parse(readFileSync(catalogPath, "utf8"));
const entries = sections.flatMap((section) => section.actions);

const src = join(dir, "src");
for (const file of readdirSync(src)) {
  if (readFileSync(join(src, file), "utf8").startsWith(header)) rmSync(join(src, file));
}
for (const { name, command } of entries) {
  writeFileSync(
    join(src, `${name}.ts`),
    `${header}\nimport { runSpacetile } from "./spacetile";\n\nexport default () => runSpacetile(${JSON.stringify(command)});\n`,
  );
}

const manifestPath = join(dir, "package.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
manifest.commands = [
  ...manifest.commands.filter((command: { name: string }) => manual.has(command.name)),
  ...entries.map(({ name, command, title, icon }) => ({
    name,
    title: raycastTitle(title),
    subtitle: "Spacetile",
    description: `Sends \`${command}\` to Spacetile.`,
    mode: "no-view",
    ...(icon && { icon }),
  })),
];
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`${entries.length} commands from ${catalogPath}`);
